(defpackage #:anypool/middleware
  (:nicknames #:lack.middleware.anypool)
  (:use #:cl)
  (:export #:*lack-middleware-anypool*
           #:*connection*))
(in-package #:anypool/middleware)

(defparameter *connection* nil)

(defparameter *lack-middleware-anypool*
  (lambda (app &rest args &key (var '*connection*) connector disconnector ping max-open-count max-idle-count timeout idle-timeout max-lifetime)
    (declare (ignore connector disconnector ping max-open-count max-idle-count timeout idle-timeout max-lifetime))
    (remf args :var)
    (let ((pool (apply #'anypool:make-pool args)))
      (lambda (env)
        (anypool:with-connection (conn pool)
          (progv (list var) (list conn)
            (funcall app env)))))))
