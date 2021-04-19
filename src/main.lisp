(defpackage #:anypool
  (:nicknames #:anypool/main)
  (:use #:cl)
  (:import-from #:bordeaux-threads
                #:make-lock
                #:with-lock-held)
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
           #:fetch
           #:putback
           #:too-many-open-connection
           #:error-max-open-limit
           #:with-connection))
(in-package #:anypool)

(defvar *default-max-open-count* 4)
(defvar *default-max-idle-count* 2)

;;
;; Wrap functions to support 0 length queues

(defun make-queue* (size)
  (if (zerop size)
      (make-array 2 :initial-contents '(2 2))
      (make-queue size)))

(defun queue-peek* (queue)
  (if (= (length queue) 2)
      (values nil nil)
      (queue-peek queue)))


;;
;; Main from here

(defstruct (pool (:constructor make-pool
                  (&key name
                        connector
                        disconnector
                        (ping (constantly t))
                        (max-open-count *default-max-open-count*)
                        (max-idle-count *default-max-idle-count*)
                        timeout
                        idle-timeout

                   &aux (storage (make-queue* (min max-open-count max-idle-count))))))
  name
  connector
  disconnector
  ping

  max-open-count
  max-idle-count
  idle-timeout  ;; Works only on SBCL
  timeout

  ;; Internal
  storage
  (active-count 0 :type fixnum)
  (timeout-in-queue-count 0 :type fixnum)
  (lock (bt:make-lock "ANYPOOL-LOCK"))

  (wait-lock (bt:make-lock "ANYPOOL-OPENWAIT-LOCK"))
  (wait-condvar (bt:make-condition-variable :name "ANYPOOL-OPENWAIT")))

(defmethod print-object ((object pool) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~@[~S ~](OPEN=~A / IDLE=~A)"
            (pool-name object)
            (pool-open-count object)
            (pool-idle-count object))))

(defun pool-idle-count (pool)
  (- (queue-count (pool-storage pool))
     (pool-timeout-in-queue-count pool)))

(defun pool-open-count (pool)
  (+ (pool-active-count pool)
     (pool-idle-count pool)))

(defstruct (item (:constructor make-item (object)))
  object
  idle-timer
  (active-p nil)
  (timeout-p nil))

(define-condition anypool-error (error) ())
(define-condition too-many-open-connection (anypool-error)
  ((limit :initarg :limit
          :reader error-max-open-limit))
  (:report (lambda (condition stream)
             (format stream "Too many open connection and couldn't open a new one (limit: ~A)"
                     (slot-value condition 'limit)))))

(defun fetch (pool)
  (with-slots (connector ping storage lock timeout wait-lock wait-condvar) pool
    (flet ((allocate-new ()
             (funcall connector))
           (can-open-p ()
             (< (pool-open-count pool) (pool-max-open-count pool))))
      (declare (inline allocate-new))
      (prog1
          (loop
            (bt:with-lock-held (lock)
              (if (zerop (pool-idle-count pool))
                  (cond
                    ((can-open-p)
                     (return (allocate-new)))
                    ((or (null timeout)
                         (and (numberp timeout)
                              (zerop timeout)))
                     (error 'too-many-open-connection
                            :limit (pool-max-open-count pool)))
                    (t
                     (bt:release-lock lock)
                     (unwind-protect
                         (or #+ccl
                             (ccl:timed-wait-on-semaphore wait-condvar (/ timeout 1000d0))
                             #-ccl
                             (bt:with-lock-held (wait-lock)
                               (bt:condition-wait wait-condvar wait-lock :timeout (/ timeout 1000d0)))
                             (error 'too-many-open-connection
                                    :limit (pool-max-open-count pool)))
                       (bt:acquire-lock lock))))
                  (let ((item (dequeue storage)))
                    (setf (item-active-p item) t)
                    #+sbcl
                    (when (item-idle-timer item)
                      ;; Release the lock once to prevent from deadlock
                      (bt:release-lock lock)
                      (sb-ext:unschedule-timer (item-idle-timer item))
                      (bt:acquire-lock lock))
                    (cond
                      ((item-timeout-p item)
                       (decf (pool-timeout-in-queue-count pool)))
                      ((or (null ping)
                           (funcall ping (item-object item)))
                       (return (item-object item)))
                      ;; Not available anymore. Just ignore
                      (t))))))
        (bt:with-lock-held (lock)
          (incf (pool-active-count pool)))))))

#+sbcl
(defun make-idle-timer (item timeout-fn)
  (sb-ext:make-timer
    (lambda ()
      (unless (item-timeout-p item)
        (funcall timeout-fn (item-object item))))
    :thread t))

(defun dequeue-timeout-resources (pool)
  (with-slots (storage lock) pool
    (loop
      (with-lock-held (lock)
        (let ((item (queue-peek* storage)))
          (when (or (null item)
                    (not (item-timeout-p item)))
            (return))
          (decf (pool-timeout-in-queue-count pool))
          (dequeue storage))))))

(defun putback (conn pool)
  (dequeue-timeout-resources pool)
  (with-slots (disconnector storage lock idle-timeout wait-lock wait-condvar) pool
    (bt:acquire-lock lock)
    (unwind-protect
        (if (queue-full-p storage)
            (progn
              (decf (pool-active-count pool))
              (bt:release-lock lock)
              (when disconnector
                (funcall disconnector conn)))
            (let ((item (make-item conn)))
              #+sbcl
              (when idle-timeout
                (setf (item-idle-timer item)
                      (make-idle-timer item
                                       (lambda (conn)
                                         (with-lock-held (lock)
                                           (unless (item-active-p item)
                                             (setf (item-timeout-p item) t)
                                             (incf (pool-timeout-in-queue-count pool))))
                                         (unless (item-active-p item)
                                           (when disconnector
                                             (funcall disconnector conn))))))
                (sb-ext:schedule-timer (item-idle-timer item)
                                       (/ idle-timeout 1000d0)))
              (enqueue item storage)
              (decf (pool-active-count pool))
              (bt:release-lock lock)
              (bt:with-lock-held (wait-lock)
                (bt:condition-notify wait-condvar))))
      (bt:release-lock lock))
    (values)))

(defmacro with-connection ((conn pool) &body body)
  (let ((g-pool (gensym "POOL")))
    `(let* ((,g-pool ,pool)
            (,conn (fetch ,g-pool)))
       (unwind-protect (progn ,@body)
         (putback ,conn ,g-pool)))))
