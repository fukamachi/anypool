(defpackage #:anypool/tests/retire
  (:use #:cl
        #:rove
        #:anypool)
  (:import-from #:anypool
                #:pool-clock)
  (:import-from #:anypool/tests/utils
                #:with-mock-functions))
(in-package #:anypool/tests/retire)

;;; An interrupt that arrives while the pool retires a connection with interrupts deferred stays
;;; pending, and is delivered when the pool allows interrupts again. Each test makes one arrive
;;; there, then checks that the retired connection is still disconnected.

(define-condition interrupted (error) ())

#+sbcl
(defmacro with-interrupt-while-retiring ((thread-var) &body body)
  "Run BODY with the first FORGET-CREATED-AT call in the thread in THREAD-VAR interrupting it."
  (let ((orig (gensym "ORIG")))
    `(let ((,orig (symbol-function 'anypool::forget-created-at))
           (,thread-var nil))
       (with-mock-functions ((anypool::forget-created-at (pool conn)
                               (when (eq (bt2:current-thread) ,thread-var)
                                 (setf ,thread-var nil)
                                 (bt2:interrupt-thread (bt2:current-thread)
                                                       (lambda () (error 'interrupted))))
                               (funcall ,orig pool conn)))
         ,@body))))

#+sbcl
(defun await (predicate)
  "Wait up to 2 seconds for PREDICATE, as a disconnect can happen in another thread."
  (loop repeat 200
        thereis (funcall predicate)
        do (sleep 0.01d0)))

#+sbcl
(defun call-in-thread (fn)
  (let ((result nil))
    (bt2:join-thread
     (bt2:make-thread (lambda ()
                        (setf result (handler-case (list :ok (funcall fn))
                                       (interrupted () :interrupted)
                                       (error () :error))))))
    result))

#+sbcl
(deftest expired-connection-is-disconnected-despite-interrupt
  (let* ((now 0)
         (disconnected '())
         (pool (make-pool :connector (let ((n 0)) (lambda () (incf n)))
                          :disconnector (lambda (c) (push c disconnected))
                          :max-open-count 1
                          :max-lifetime 1000))
         (conn (progn (setf (pool-clock pool) (lambda () now))
                      (fetch pool))))
    (setf now (* 2 internal-time-units-per-second))
    (with-interrupt-while-retiring (target)
      (ok (eq (call-in-thread (lambda ()
                     (setf target (bt2:current-thread))
                     (putback conn pool)))
              :interrupted)))
    (ok (await (lambda () (equal disconnected (list conn)))) "The expired connection is disconnected")
    (ok (await (lambda () (= (pool-active-count pool) 0))) "The slot is freed")))

#+sbcl
(deftest surplus-connection-is-disconnected-despite-interrupt
  (let* ((disconnected '())
         (pool (make-pool :connector (let ((n 0)) (lambda () (incf n)))
                          :disconnector (lambda (c) (push c disconnected))
                          :max-open-count 1
                          :max-idle-count 0))
         (conn (fetch pool)))
    (with-interrupt-while-retiring (target)
      (ok (eq (call-in-thread (lambda ()
                     (setf target (bt2:current-thread))
                     (putback conn pool)))
              :interrupted)))
    (ok (await (lambda () (equal disconnected (list conn)))) "The surplus connection is disconnected")
    (ok (await (lambda () (= (pool-active-count pool) 0))) "The slot is freed")))

#+sbcl
(deftest rejected-connection-is-disconnected-despite-interrupt
  (let* ((disconnected '())
         (rejecting nil)
         (pool (make-pool :connector (let ((n 0)) (lambda () (incf n)))
                          :disconnector (lambda (c) (push c disconnected))
                          :ping (lambda (c) (declare (ignore c)) (not rejecting))
                          :max-open-count 1)))
    (putback (fetch pool) pool)
    (setf rejecting t)
    (with-interrupt-while-retiring (target)
      (ok (eq (call-in-thread (lambda ()
                     (setf target (bt2:current-thread))
                     (fetch pool)))
              :interrupted)))
    (ok (await (lambda () (equal disconnected (list 1)))) "The rejected connection is disconnected")
    (ok (await (lambda () (= (pool-active-count pool) 0))) "The slot is freed")))

#+sbcl
(deftest failed-fetch-disconnects-its-connection-despite-interrupt
  (let* ((disconnected '())
         (pool (make-pool :connector (let ((n 0)) (lambda () (incf n)))
                          :disconnector (lambda (c) (push c disconnected))
                          :ping (lambda (c) (declare (ignore c)) (error "ping failed"))
                          :max-open-count 1)))
    (putback (fetch pool) pool)
    (with-interrupt-while-retiring (target)
      ;; The ping's error and the interrupt both end the fetch; which one shows depends on when
      ;; the interrupt is delivered.
      (ok (member (call-in-thread (lambda ()
                                    (setf target (bt2:current-thread))
                                    (fetch pool)))
                  '(:interrupted :error))))
    (ok (await (lambda () (equal disconnected (list 1)))) "The connection is disconnected")
    (ok (await (lambda () (= (pool-active-count pool) 0))) "The slot is freed")))
