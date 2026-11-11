(defpackage #:anypool/tests/deadline
  (:use #:cl
        #:rove
        #:anypool)
  (:import-from #:anypool
                #:pool-lock))
(in-package #:anypool/tests/deadline)

;;; SB-SYS:WITH-DEADLINE signals from inside a blocking lock grab, interrupts deferred or not. Each
;;; test passes the deadline, then makes a cleanup wait for the pool lock.

#+sbcl
(defun busy-wait (seconds)
  "Wait without a blocking call, so a deadline passes unsignalled."
  (let ((end (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop while (< (get-internal-real-time) end))))

#+sbcl
(defun run-with-deadline (seconds fn)
  (bt2:make-thread
   (lambda ()
     (handler-case (sb-sys:with-deadline (:seconds seconds)
                     (list :ok (funcall fn)))
       (sb-sys:deadline-timeout () (list :deadline))
       (error (e) (list :error e))))))

#+sbcl
(defun hold-lock (pool seconds)
  (bt2:with-lock-held ((pool-lock pool))
    (sleep seconds)))

#+sbcl
(deftest putback-after-deadline-returns-connection
  (let* ((pool (make-pool :connector (let ((n 0)) (lambda () (incf n)))
                          :max-open-count 1))
         (in-body (bt2:make-semaphore))
         (locked (bt2:make-semaphore))
         (user (run-with-deadline 0.2d0
                                  (lambda ()
                                    (with-connection (conn pool)
                                      (bt2:signal-semaphore in-body)
                                      (bt2:wait-on-semaphore locked)
                                      (busy-wait 0.4d0)
                                      conn)))))
    (ok (bt2:wait-on-semaphore in-body :timeout 5))
    (bt2:with-lock-held ((pool-lock pool))
      (bt2:signal-semaphore locked)
      (sleep 1))
    (ok (equal (bt2:join-thread user) '(:ok 1)))
    (ok (= (pool-active-count pool) 0) "The slot is freed")
    (ok (= (pool-idle-count pool) 1) "The connection is queued")))

#+sbcl
(deftest fetch-cleanup-after-deadline-frees-slot
  (let* ((connecting (bt2:make-semaphore))
         (pool (make-pool :connector (lambda ()
                                       (bt2:signal-semaphore connecting)
                                       (busy-wait 0.4d0)
                                       (error "connect failed"))
                          :max-open-count 1))
         (user (run-with-deadline 0.2d0 (lambda () (fetch pool)))))
    (ok (bt2:wait-on-semaphore connecting :timeout 5))
    (hold-lock pool 1)
    (ok (eq (first (bt2:join-thread user)) :error) "The connector's error propagates")
    (ok (= (pool-active-count pool) 0) "The slot is freed")))

#+sbcl
(deftest waiting-fetch-after-deadline-retakes-lock
  (let* ((pool (make-pool :connector (let ((n 0)) (lambda () (incf n)))
                          :max-open-count 1
                          :timeout 5000))
         (conn (fetch pool))
         (waiter (run-with-deadline 0.2d0 (lambda () (fetch pool)))))
    (sleep 0.1)
    ;; The deadline ends the wait while the pool lock is taken.
    (hold-lock pool 0.6)
    (ok (equal (bt2:join-thread waiter) '(:deadline)))
    (ok (= (pool-active-count pool) 1) "Only the held connection counts")
    (putback conn pool)
    (ok (eql (fetch pool) conn) "The pool lock is not left taken")))

#+sbcl
(deftest connect-after-deadline-keeps-connection
  (let* ((connecting (bt2:make-semaphore))
         (disconnected '())
         (pool (make-pool :connector (lambda ()
                                       (bt2:signal-semaphore connecting)
                                       (busy-wait 0.4d0)
                                       :conn)
                          :disconnector (lambda (c) (push c disconnected))
                          :max-open-count 1))
         (user (run-with-deadline 0.2d0 (lambda () (fetch pool)))))
    (ok (bt2:wait-on-semaphore connecting :timeout 5))
    ;; The connector returns after the deadline, while the pool lock is taken.
    (hold-lock pool 1)
    (let ((result (bt2:join-thread user)))
      (ok (or (equal result '(:ok :conn))
              (equal disconnected '(:conn)))
          (format nil "The connection is lent or disconnected, not lost: ~S" result)))))
