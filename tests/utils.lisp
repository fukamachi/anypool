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
(defun start-waiting-fetch (fetch-fn lock)
  "Run FETCH-FN in a new thread and return the thread once it has released LOCK to wait.
The thread pauses right after that release, so a wakeup sent in the gap before it starts
waiting is lost unless the waiter guards against it. The thread returns (:ok value) or
(:error condition)."
  (let* ((released (bt2:make-semaphore))
         (orig-release (symbol-function 'bt2:release-lock))
         (pending t)
         (waiter nil)
         (thread
           (bt2:make-thread
            (lambda ()
              (setf waiter (bt2:current-thread))
              (with-mock-functions ((bt2:release-lock (l)
                                      (funcall orig-release l)
                                      (when (and pending
                                                 (eq l lock)
                                                 (eq (bt2:current-thread) waiter))
                                        (setf pending nil)
                                        (bt2:signal-semaphore released)
                                        (sleep 0.2))
                                      l))
                (handler-case (list :ok (funcall fetch-fn))
                  (error (e) (list :error e))))))))
    (unless (bt2:wait-on-semaphore released :timeout 5)
      ;; Joining a thread stuck elsewhere would hang the test run instead of failing it.
      (error "The fetch never started waiting: ~S"
             (if (bt2:thread-alive-p thread)
                 thread
                 (bt2:join-thread thread))))
    thread))
