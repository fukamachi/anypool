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

                   &aux (storage (make-queue (min max-open-count max-idle-count))))))
  name
  connector
  disconnector
  ping

  max-open-count
  max-idle-count

  ;; Internal
  storage
  (active-count 0 :type fixnum)
  (lock (bt:make-lock "ANYPOOL-LOCK")))

(defmethod print-object ((object pool) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~@[~S ~](OPEN=~A / IDLE=~A)"
            (pool-name object)
            (pool-max-open-count object)
            (pool-max-idle-count object))))

(defun pool-idle-count (pool)
  (queue-count (pool-storage pool)))

(defun pool-open-count (pool)
  (+ (pool-active-count pool)
     (pool-idle-count pool)))

(defun fetch (pool)
  (with-slots (connector disconnector ping storage lock) pool
    (flet ((allocate-new ()
             ;; TODO: Wait until available
             (assert (< (pool-open-count pool) (pool-max-open-count pool)))
             (funcall connector)))
      (declare (inline allocate-new))
      (with-lock-held (lock)
        (prog1
            (if (queue-empty-p storage)
                (allocate-new)
                (let ((object (dequeue storage)))
                  ;; Check if it's still available
                  (or (funcall ping object)
                      (progn
                        (when disconnector
                          (funcall disconnector object))
                        (allocate-new)))))
          (incf (pool-active-count pool)))))))

(defun putback (conn pool)
  (with-slots (disconnector storage lock) pool
    (with-lock-held (lock)
      (if (queue-full-p storage)
          (when disconnector
            (funcall disconnector conn))
          (enqueue conn storage))
      (decf (pool-active-count pool)))))
