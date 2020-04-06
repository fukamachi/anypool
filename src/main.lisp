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
                #:queue-empty-p)
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
           #:too-many-open-connection))
(in-package #:anypool)

(defvar *default-max-open-count* 4)
(defvar *default-max-idle-count* 2)

(defstruct (pool (:constructor make-pool
                  (&key name
                        connector
                        disconnector
                        (ping (constantly t))
                        (max-open-count *default-max-open-count*)
                        (max-idle-count *default-max-idle-count*)
                        timeout
                        idle-timeout

                   &aux (storage (make-queue (min max-open-count max-idle-count))))))
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
  (timeout-p nil))

(define-condition anypool-error (error) ())
(define-condition too-many-open-connection (anypool-error)
  ((limit :initarg :limit))
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
            (if (queue-empty-p storage)
                (if (can-open-p)
                    (return (allocate-new))
                    (bt:with-lock-held (wait-lock)
                      (or (bt:condition-wait wait-condvar wait-lock :timeout (/ timeout 1000d0))
                          (error 'too-many-open-connection
                                 :limit (pool-max-open-count pool)))))
                (with-lock-held (lock)
                  (let ((item (dequeue storage)))
                    (when (item-idle-timer item)
                      #+sbcl
                      (sb-ext:unschedule-timer (item-idle-timer item)))
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
        (setf (item-timeout-p item) t)
        (funcall timeout-fn (item-object item))))
    :thread nil))

(defun putback (conn pool)
  (with-slots (disconnector storage lock idle-timeout wait-lock wait-condvar) pool
    (with-lock-held (lock)
      (if (queue-full-p storage)
          (when disconnector
            (funcall disconnector conn))
          (let ((item (make-item conn)))
            #+sbcl
            (when idle-timeout
              (setf (item-idle-timer item)
                    (make-idle-timer item
                                     (lambda (conn)
                                       (with-lock-held (lock)
                                         (incf (pool-timeout-in-queue-count pool)))
                                       (when disconnector
                                         (funcall disconnector conn)))))
              (sb-ext:schedule-timer (item-idle-timer item)
                                     (/ idle-timeout 1000d0)))
            (enqueue item storage)
            (bt:with-lock-held (wait-lock)
              (bt:condition-notify wait-condvar))))
      (decf (pool-active-count pool)))
    (values)))
