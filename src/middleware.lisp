(defpackage #:anypool/middleware
  (:nicknames #:lack.middleware.anypool)
  (:use #:cl)
  (:export #:*lack-middleware-anypool*
           #:*connection*))
(in-package #:anypool/middleware)

(defparameter *connection* nil)

(defparameter *lack-middleware-anypool*
  (lambda (app &rest args &key (var '*connection*) connector disconnector ping max-open-count max-idle-count timeout idle-timeout)
    (declare (ignore connector disconnector ping max-open-count max-idle-count timeout idle-timeout))
    (remf args :var)
    (let ((pool (apply #'anypool:make-pool args)))
      (lambda (env)
        (let ((conn (anypool:fetch pool)))
          (progv (list var) (list conn)
            (unwind-protect (funcall app env)
              (anypool:putback conn pool))))))))
