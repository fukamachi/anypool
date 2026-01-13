(defsystem "anypool"
  :version "0.1.0"
  :author "Eitaro Fukamachi"
  :license "BSD 2-Clause"
  :description "General-purpose pooling library"
  :depends-on ("bordeaux-threads"
               "cl-speedy-queue")
  :components
  ((:module "src"
    :components ((:file "main"))))
  :in-order-to ((test-op (test-op "anypool/tests"))))

(defsystem "anypool/tests"
  :depends-on ("rove"
               "anypool")
  :components
  ((:module "tests"
    :components ((:file "utils")
                 (:file "main" :depends-on ("utils")))))
  :perform (test-op (o c) (symbol-call :rove '#:run c)))

(defsystem "anypool/middleware"
  :depends-on ("anypool")
  :components ((:file "src/middleware")))
