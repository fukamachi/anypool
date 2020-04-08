(defpackage #:anypool/middleware
  (:nicknames #:lack.middleware.anypool)
  (:use #:cl)
  (:export #:*lack-middleware-anypool*))
(in-package #:anypool/middleware)

(defparameter *lack-middleware-anypool*
  (lambda (app &rest args &key var connector disconnector ping max-open-count max-idle-count timeout idle-timeout)
    (declare (ignore connector disconnector ping max-open-count max-idle-count timeout idle-timeout))
    (remf args :var)
    (let ((pool (apply #'anypool:make-pool args)))
      (lambda (env)
        (let ((conn (anypool:fetch pool)))
          (progv (list var) (list conn)
            (unwind-protect (funcall app env)
              (anypool:putback conn pool))))))))
