(defpackage #:anypool/tests/utils
  (:use #:cl)
  (:export #:*mock-function*
           #:with-mock-functions))
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
