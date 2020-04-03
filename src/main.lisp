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
           #:putback))
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
                        idle-timeout

                   &aux (storage (make-queue (min max-open-count max-idle-count))))))
  name
  connector
  disconnector
  ping

  max-open-count
  max-idle-count
  idle-timeout  ;; Works only on SBCL

  ;; Internal
  storage
  (active-count 0 :type fixnum)
  (timeout-in-queue-count 0 :type fixnum)
  (lock (bt:make-lock "ANYPOOL-LOCK")))

(defmethod print-object ((object pool) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~@[~S ~](OPEN=~A / IDLE=~A)"
            (pool-name object)
            (pool-max-open-count object)
            (pool-max-idle-count object))))

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

(defun fetch (pool)
  (with-slots (connector disconnector ping storage lock) pool
    (flet ((allocate-new ()
             ;; TODO: Wait until available
             (assert (< (pool-open-count pool) (pool-max-open-count pool)))
             (funcall connector)))
      (declare (inline allocate-new))
      (with-lock-held (lock)
        (prog1
            (loop
              (if (queue-empty-p storage)
                  (return (allocate-new))
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
                      (t
                       (when disconnector
                         (funcall disconnector (item-object item))))))))
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
  (with-slots (disconnector storage lock idle-timeout) pool
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
            (enqueue item storage)))
      (decf (pool-active-count pool)))))
