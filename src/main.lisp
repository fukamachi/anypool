(defpackage #:anypool
  (:nicknames #:anypool/main)
  (:use #:cl)
  (:import-from #:bordeaux-threads)
  (:import-from #:cl-speedy-queue
                #:make-queue
                #:enqueue
                #:dequeue
                #:queue-count
                #:queue-full-p
                #:queue-peek)
  (:export #:*default-max-open-count*
           #:*default-max-idle-count*
           #:pool
           #:make-pool
           #:pool-name
           #:pool-max-open-count
           #:pool-max-idle-count
           #:pool-idle-timeout
           #:pool-active-count
           #:pool-idle-count
           #:pool-open-count
           #:pool-overflow-count
           #:fetch
           #:putback
           #:too-many-open-connection
           #:error-max-open-limit
           #:with-connection))
(in-package #:anypool)

(defvar *default-max-open-count* 4)
(defvar *default-max-idle-count* 2)

(defun make-queue* (size)
  (if (zerop size)
      (make-array 2 :initial-contents '(2 2))
      (make-queue size)))

(defun queue-peek* (queue)
  (if (= (length queue) 2)
      (values nil nil)
      (queue-peek queue)))

(defstruct (pool (:constructor nil))  ; Don't generate constructor for base struct
  name
  connector
  disconnector
  ping
  max-open-count
  max-idle-count
  unlimited-p
  idle-timeout
  timeout
  ;; Internal
  storage ; queue object
  (active-count 0 :type fixnum)
  (lock (bt2:make-lock :name "ANYPOOL-LOCK"))
  (wait-lock (bt2:make-lock :name "ANYPOOL-OPENWAIT-LOCK"))
  (wait-condvar (bt2:make-condition-variable :name "ANYPOOL-OPENWAIT")))

(defstruct (pool-without-timeout
            (:include pool)
            (:conc-name pool-)
            (:constructor %make-pool-without-timeout)))

(defstruct (pool-with-timeout
            (:include pool)
            (:conc-name pool-)
            (:constructor %make-pool-with-timeout))
  (timeout-in-queue-count 0 :type fixnum))

(defstruct (item (:constructor make-item (object)))
  object
  idle-timer
  (active-p nil)
  (timeout-p nil))

(defmethod print-object ((object pool) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~@[~S ~](OPEN=~A / IDLE=~A)"
            (pool-name object)
            (pool-open-count object)
            (pool-idle-count object))))

(defun pool-idle-count (pool)
  (etypecase pool
    (pool-without-timeout
     (queue-count (pool-storage pool)))
    (pool-with-timeout
     (- (queue-count (pool-storage pool))
        (pool-timeout-in-queue-count pool)))))

(defun pool-open-count (pool)
  (+ (pool-active-count pool)
     (pool-idle-count pool)))

(defun pool-overflow-count (pool)
  "Number of connections beyond max-open-count (0 if unlimited)."
  (if (pool-unlimited-p pool)
      0
      (max 0 (- (pool-active-count pool)
                (pool-max-open-count pool)))))

(define-condition anypool-error (error) ())
(define-condition too-many-open-connection (anypool-error)
  ((limit :initarg :limit
          :reader error-max-open-limit))
  (:report (lambda (condition stream)
             (format stream "Too many open connection and couldn't open a new one (limit: ~A)"
                     (slot-value condition 'limit)))))

(defun make-pool (&key name
                       connector
                       disconnector
                       (ping (constantly t))
                       (max-open-count *default-max-open-count*)
                       (max-idle-count *default-max-idle-count*)
                       timeout
                       idle-timeout)
  "Create a connection pool. Returns pool-without-timeout or pool-with-timeout based on idle-timeout."
  (let* ((unlimited-p (null max-open-count))
         (max-open-count (or max-open-count most-positive-fixnum))
         (storage (make-queue* (min max-open-count max-idle-count))))
    (if idle-timeout
        (%make-pool-with-timeout
         :name name
         :connector connector
         :disconnector disconnector
         :ping ping
         :max-open-count max-open-count
         :max-idle-count max-idle-count
         :unlimited-p unlimited-p
         :idle-timeout idle-timeout
         :timeout timeout
         :storage storage)
        (%make-pool-without-timeout
         :name name
         :connector connector
         :disconnector disconnector
         :ping ping
         :max-open-count max-open-count
         :max-idle-count max-idle-count
         :unlimited-p unlimited-p
         :idle-timeout nil
         :timeout timeout
         :storage storage))))

(defmacro define-fetch-impl (name pool-type &key idle-check dequeue-and-validate)
  "Generate a fetch implementation with type-specific logic."
  `(defun ,name (pool)
     (declare (type ,pool-type pool))
     (with-slots (connector ping storage lock timeout unlimited-p wait-lock wait-condvar) pool
       (flet ((allocate-new ()
                (funcall connector))
              (can-open-p ()
                (or unlimited-p
                    (< (pool-open-count pool) (pool-max-open-count pool)))))
         (declare (inline allocate-new))
         (loop
           (bt2:with-lock-held (lock)
             (if ,idle-check
                 ;; Common wait-or-allocate logic
                 (cond
                   ((can-open-p)
                    (return (prog1 (allocate-new)
                              (incf (pool-active-count pool)))))
                   ((and (numberp timeout)
                         (zerop timeout))
                    (error 'too-many-open-connection
                           :limit (pool-max-open-count pool)))
                   (t
                    (bt2:release-lock lock)
                    (unwind-protect
                        (or #+ccl
                            (if timeout
                                (ccl:timed-wait-on-semaphore wait-condvar (/ timeout 1000d0))
                                (ccl:wait-on-semaphore wait-condvar))
                            #-ccl
                            (bt2:with-lock-held (wait-lock)
                              (bt2:condition-wait wait-condvar wait-lock
                                                 :timeout (and timeout (/ timeout 1000d0))))
                            (error 'too-many-open-connection
                                   :limit (pool-max-open-count pool)))
                      (bt2:acquire-lock lock))))
                 ;; Type-specific dequeue and validation
                 ,dequeue-and-validate)))))))

(define-fetch-impl %fetch-without-timeout pool-without-timeout
  :idle-check (zerop (queue-count storage))
  :dequeue-and-validate
  (let ((conn (dequeue storage)))
    (cond
      ((or (null ping)
           (funcall ping conn))
       (incf (pool-active-count pool))
       (return conn))
      ;; Ping failed, discard and continue
      (t))))

#+sbcl
(defun make-idle-timer (item timeout-fn)
  (sb-ext:make-timer
    (lambda ()
      (unless (item-timeout-p item)
        (funcall timeout-fn (item-object item))))
    :thread t))

(define-fetch-impl %fetch-with-timeout pool-with-timeout
  :idle-check (<= (pool-idle-count pool) 0) ; Fail-safe for cases where pool-idle-count is negative
  :dequeue-and-validate
  (let ((item (dequeue storage)))
    #+sbcl
    (when (item-idle-timer item)
      ;; Mark as active BEFORE releasing lock to prevent race condition
      (setf (item-active-p item) t)
      ;; Release the lock once to prevent from deadlock
      (bt2:release-lock lock)
      (sb-ext:unschedule-timer (item-idle-timer item))
      (bt2:acquire-lock lock))
    (cond
      ((item-timeout-p item)
       (decf (pool-timeout-in-queue-count pool)))
      ((or (null ping)
           (funcall ping (item-object item)))
       ;; active-p is already set above
       (incf (pool-active-count pool))
       (return (item-object item)))
      ;; Not available anymore. Just ignore
      (t))))

(defun fetch (pool)
  "Fetch a connection from the pool."
  (etypecase pool
    (pool-without-timeout (%fetch-without-timeout pool))
    (pool-with-timeout (%fetch-with-timeout pool))))

(defmacro define-putback-impl (name pool-type &key before-putback enqueue-logic)
  "Generate a putback implementation with type-specific logic."
  `(defun ,name (conn pool)
     (declare (type ,pool-type pool))
     ,@(when before-putback (list before-putback))
     (with-slots (disconnector storage lock wait-lock wait-condvar) pool
       (bt2:acquire-lock lock)
       (unwind-protect
           (if (queue-full-p storage)
               (progn
                 (decf (pool-active-count pool))
                 (bt2:release-lock lock)
                 (when disconnector
                   (funcall disconnector conn)))
               (progn
                 ,enqueue-logic
                 (decf (pool-active-count pool))
                 (bt2:release-lock lock)
                 (bt2:with-lock-held (wait-lock)
                   (bt2:condition-notify wait-condvar))))
         (bt2:release-lock lock))
       (values))))

(defun dequeue-timeout-resources (pool)
  (declare (type pool-with-timeout pool))
  (with-slots (storage lock) pool
    (loop
      (bt2:with-lock-held (lock)
        (let ((item (queue-peek* storage)))
          (when (or (null item)
                    (not (item-timeout-p item)))
            (return))
          (decf (pool-timeout-in-queue-count pool))
          (dequeue storage))))))

(define-putback-impl %putback-without-timeout pool-without-timeout
  :enqueue-logic
  (enqueue conn storage))

(define-putback-impl %putback-with-timeout pool-with-timeout
  :before-putback
  (dequeue-timeout-resources pool)
  :enqueue-logic
  (let ((item (make-item conn)))
    #+sbcl
    (with-slots (idle-timeout) pool
      (setf (item-idle-timer item)
            (make-idle-timer item
                             (lambda (conn)
                               (let ((activep
                                       (bt2:with-lock-held (lock)
                                         (let ((activep (item-active-p item)))
                                           (unless activep
                                             (setf (item-timeout-p item) t)
                                             (incf (pool-timeout-in-queue-count pool)))
                                           activep))))
                                 (unless activep
                                   (when disconnector
                                     (funcall disconnector conn)))))))
      (sb-ext:schedule-timer (item-idle-timer item)
                             (/ idle-timeout 1000d0)))
    (enqueue item storage)))

(defun putback (conn pool)
  "Return a connection to the pool."
  (etypecase pool
    (pool-without-timeout (%putback-without-timeout conn pool))
    (pool-with-timeout (%putback-with-timeout conn pool))))

(defmacro with-connection ((conn pool) &body body)
  (let ((g-pool (gensym "POOL")))
    `(let* ((,g-pool ,pool)
            (,conn (fetch ,g-pool)))
       (unwind-protect (progn ,@body)
         (putback ,conn ,g-pool)))))
