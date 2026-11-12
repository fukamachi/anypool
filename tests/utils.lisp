(defpackage #:anypool/tests/utils
  (:use #:cl)
  (:export #:*mock-function*
           #:with-mock-functions
           #:start-waiting-fetch))

(in-package #:anypool/tests/utils)

(defvar *mock-function*)

#+sbcl
(defun call-with-mock-function (fn-name fn main)
  (let ((*mock-function* (if (boundp '*mock-function*)
                             *mock-function*
                             (make-hash-table :test 'eq)))
        (orig-fn (symbol-function fn-name)))
    (unwind-protect (progn
                      (setf (gethash fn-name *mock-function*) orig-fn)
                      (sb-ext:without-package-locks
                        (setf (symbol-function fn-name) fn))
                      (funcall main))
      (sb-ext:without-package-locks
        (setf (symbol-function fn-name) orig-fn))
      (remhash fn-name *mock-function*))))

(defmacro with-mock-functions ((&rest functions) &body body)
  (if functions
      (destructuring-bind (name &rest fn-body)
          (first functions)
        `(call-with-mock-function ',name (lambda ,@fn-body)
                                  (lambda ()
                                    (declare (notinline ,name))
                                    (with-mock-functions (,@(rest functions)) ,@body))))
      `(progn ,@body)))

#+sbcl
(defun start-waiting-fetch (fetch-fn)
  "Run FETCH-FN in a new thread and return the thread once it waits for a slot. A fetch holds the
pool lock until its wait begins, so a pool call made after this returns comes after that.
The thread returns (:ok value) or (:error condition)."
  (let ((waiting (bt2:make-semaphore))
        (orig-wait (symbol-function 'anypool::wait-for-slot))
        (waiter nil))
    ;; Mocked only until the wait begins, so mocks from several calls never overlap.
    (with-mock-functions ((anypool::wait-for-slot (pool &rest args)
                            (when (eq (bt2:current-thread) waiter)
                              (bt2:signal-semaphore waiting))
                            (apply orig-wait pool args)))
      (let ((thread (bt2:make-thread
                     (lambda ()
                       (setf waiter (bt2:current-thread))
                       (handler-case (list :ok (funcall fetch-fn))
                         (error (e) (list :error e)))))))
        (unless (bt2:wait-on-semaphore waiting :timeout 5)
          ;; Joining a thread stuck elsewhere would hang the test run instead of failing it.
          (error "The fetch never started waiting: ~S"
                 (if (bt2:thread-alive-p thread)
                     thread
                     (bt2:join-thread thread))))
        thread))))
