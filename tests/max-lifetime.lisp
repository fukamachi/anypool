(defpackage #:anypool/tests/max-lifetime
  (:use #:cl
        #:rove
        #:anypool)
  (:import-from #:anypool
                #:pool-clock
                #:pool-created-at-table
                #:pool-lock
                #:pool-timeout-in-queue-count)
  (:import-from #:anypool/tests/utils
                #:with-mock-functions
                #:start-waiting-fetch))
(in-package #:anypool/tests/max-lifetime)

(defstruct conn
  id
  target
  (disconnect-count 0))

(defstruct backend
  (target :a)
  (created '())
  (lock (bt2:make-lock :name "test backend")))

(defun backend-connector (backend)
  (lambda ()
    (bt2:with-lock-held ((backend-lock backend))
      (let ((conn (make-conn :id (1+ (length (backend-created backend)))
                             :target (backend-target backend))))
        (push conn (backend-created backend))
        conn))))

(defun backend-created-count (backend)
  (length (backend-created backend)))

(defun disconnect (conn)
  (incf (conn-disconnect-count conn)))

(defun make-lifetime-pool (backend &rest args)
  ;; ARGS come first so that they override the defaults below.
  (apply #'make-pool (append args
                             (list :name "lifetime pool"
                                   :connector (backend-connector backend)
                                   :disconnector #'disconnect))))

(defun install-manual-clock (pool)
  "Make POOL read a clock that only moves when the returned function is called with milliseconds."
  (let ((now 0))
    (setf (pool-clock pool) (lambda () now))
    (lambda (milliseconds)
      (incf now (* milliseconds (/ internal-time-units-per-second 1000))))))

(defun tracked-count (pool)
  (hash-table-count (pool-created-at-table pool)))

(defparameter *variants*
  '(()
    #+sbcl (:idle-timeout 600000))
  "Extra MAKE-POOL arguments; each lifetime test runs with and without idle-timeout.")

(deftest max-lifetime-disabled
  (dolist (args '(() (:max-lifetime nil)))
    (let* ((backend (make-backend))
           (pool (apply #'make-lifetime-pool backend args)))
      (setf (pool-clock pool) (lambda () (error "The clock must not be read")))
      (ok (null (pool-max-lifetime pool)))
      (ok (null (pool-created-at-table pool)) "No lifetime bookkeeping")
      (let ((conn (fetch pool)))
        (putback conn pool)
        (ok (eq (fetch pool) conn) "Connections are reused as before"))))
  (testing "a connector may keep returning the same object"
    (let ((pool (make-pool :connector (constantly :shared) :max-open-count 2)))
      (ok (eq (fetch pool) :shared))
      (ok (eq (fetch pool) :shared)))))

(deftest max-lifetime-validation
  (dolist (value (list 1 60000 1/3 0.5 2.5d0))
    (ok (eql (pool-max-lifetime (make-pool :connector (constantly nil) :max-lifetime value))
             value)
        (format nil "~S is accepted" value)))
  (dolist (value (list 0 0.0 -0.0 -1 -1/2 "1000" :forever t #c(1 1)
                       #+sbcl sb-ext:double-float-positive-infinity))
    (ok (signals (make-pool :connector (constantly nil) :max-lifetime value) 'type-error)
        ;; ~A, not ~S: the description can be printed readably, and an infinity has no readable form.
        (format nil "~A is rejected" value))))

(defun lent-again-at-p (max-lifetime units)
  "Whether a connection made at clock 0 and returned at once is lent again when the clock reads UNITS."
  (let* ((pool (make-lifetime-pool (make-backend) :max-lifetime max-lifetime))
         (now 0))
    (setf (pool-clock pool) (lambda () now))
    (let ((conn (fetch pool)))
      (putback conn pool)
      (setf now units)
      (eq (fetch pool) conn))))

(deftest max-lifetime-boundary
  (let ((limit internal-time-units-per-second))
    (ok (lent-again-at-p 1000 (1- limit)) "Just before the limit")
    (ng (lent-again-at-p 1000 limit) "Exactly at the limit")
    (ng (lent-again-at-p 1000 (1+ limit)) "After the limit"))
  (testing "fractional milliseconds are compared exactly"
    (dolist (max-lifetime (list 1/3 1.5 2.5d0))
      (let ((limit (/ (* (rational max-lifetime) internal-time-units-per-second) 1000)))
        (ok (lent-again-at-p max-lifetime (1- (ceiling limit)))
            (format nil "~S: just before the limit" max-lifetime))
        (ng (lent-again-at-p max-lifetime (ceiling limit))
            (format nil "~S: at the limit" max-lifetime))))))

(deftest max-lifetime-not-extended-by-reuse
  (dolist (args *variants*)
    (let* ((backend (make-backend))
           (pool (apply #'make-lifetime-pool backend :max-lifetime 1000 args))
           (advance (install-manual-clock pool))
           (first-conn (fetch pool)))
      (funcall advance 50)
      (putback first-conn pool)
      (ok (loop repeat 9
                always (progn
                         (funcall advance 50)
                         (let ((conn (fetch pool)))
                           (funcall advance 50)
                           (putback conn pool)
                           (eq conn first-conn))))
          "Reused while younger than max-lifetime")
      (funcall advance 50)
      (let ((conn (fetch pool)))
        (ng (eq conn first-conn) "Replaced once max-lifetime has passed since creation")
        (ok (= (conn-disconnect-count first-conn) 1))
        (ok (= (backend-created-count backend) 2))
        (putback conn pool)))))

(deftest max-lifetime-reached-while-borrowed
  (dolist (args *variants*)
    (let* ((pool (apply #'make-lifetime-pool (make-backend) :max-lifetime 1000 args))
           (advance (install-manual-clock pool))
           (conn (fetch pool)))
      (funcall advance 5000)
      (ok (= (conn-disconnect-count conn) 0) "Not disconnected while borrowed")
      (ok (= (pool-active-count pool) 1))
      (putback conn pool)
      (ok (= (conn-disconnect-count conn) 1) "Disconnected on putback")
      (ok (= (pool-open-count pool) 0))
      (ok (= (pool-idle-count pool) 0))
      (ok (= (tracked-count pool) 0))
      (let ((next (fetch pool)))
        (ng (eq next conn))
        (putback next pool))
      (ok (= (conn-disconnect-count conn) 1) "Disconnected only once"))))

(deftest max-lifetime-reached-while-idle
  (dolist (args *variants*)
    (let* ((pool (apply #'make-lifetime-pool (make-backend) :max-lifetime 1000 args))
           (advance (install-manual-clock pool))
           (conn (fetch pool)))
      (putback conn pool)
      (funcall advance 5000)
      (ok (= (pool-idle-count pool) 1) "Not collected without an access")
      (ok (= (conn-disconnect-count conn) 0))
      (let ((next (fetch pool)))
        (ng (eq next conn) "The expired connection is not lent")
        (ok (= (conn-disconnect-count conn) 1))
        (ok (= (pool-open-count pool) 1))
        (ok (= (pool-idle-count pool) 0))
        (ok (= (tracked-count pool) 1))))))

(deftest max-lifetime-independent-of-ping
  (dolist (args *variants*)
    (testing ":ping nil"
      (let* ((pool (apply #'make-lifetime-pool (make-backend) :max-lifetime 1000 :ping nil args))
             (advance (install-manual-clock pool))
             (conn (fetch pool)))
        (putback conn pool)
        (funcall advance 1000)
        (ng (eq (fetch pool) conn))))
    (testing "an expired connection is dropped without pinging it"
      (let* ((pinged '())
             (pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 1000
                          :ping (lambda (conn) (push conn pinged) t)
                          args))
             (advance (install-manual-clock pool))
             (conn (fetch pool)))
        (putback conn pool)
        (funcall advance 1000)
        (ng (eq (fetch pool) conn))
        (ok (null pinged))))
    (testing "a connection that expires during ping is not lent"
      (let* ((pinged '())
             (advance nil)
             (pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 1000
                          :ping (lambda (conn)
                                  (push conn pinged)
                                  (funcall advance 2000)
                                  t)
                          args))
             (conn (progn (setf advance (install-manual-clock pool))
                          (fetch pool))))
        (putback conn pool)
        (funcall advance 500)
        (ng (eq (fetch pool) conn))
        (ok (equal pinged (list conn)) "Pinged while still within max-lifetime")
        (ok (= (conn-disconnect-count conn) 1))
        (ok (= (pool-active-count pool) 1))
        (ok (= (tracked-count pool) 1))))
    (testing "an error from ping is not taken as a failed ping"
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 1000
                          :ping (lambda (conn) (error "ping ~A failed" (conn-id conn)))
                          args))
             (conn (fetch pool)))
        (install-manual-clock pool)
        (putback conn pool)
        (ok (signals (fetch pool) 'simple-error))
        (ok (= (conn-disconnect-count conn) 1) "Retired, not left open")
        (ok (= (pool-open-count pool) 0))
        (ok (= (tracked-count pool) 0))))))

#+sbcl
(deftest max-lifetime-with-idle-timeout
  (testing "idle-timeout comes first"
    (let* ((pool (make-lifetime-pool (make-backend) :max-lifetime 60000 :idle-timeout 50))
           (conn (fetch pool)))
      (install-manual-clock pool)
      (putback conn pool)
      (sleep 0.3)
      (ok (= (conn-disconnect-count conn) 1))
      (ok (= (tracked-count pool) 0))
      (ok (= (pool-idle-count pool) 0))
      (let ((next (fetch pool)))
        (ng (eq next conn))
        (ok (= (conn-disconnect-count conn) 1))
        (ok (= (pool-open-count pool) 1)))))
  (testing "max-lifetime comes first"
    (let* ((pool (make-lifetime-pool (make-backend) :max-lifetime 1000 :idle-timeout 200))
           (advance (install-manual-clock pool))
           (conn (fetch pool)))
      (putback conn pool)
      (funcall advance 5000)
      (let ((next (fetch pool)))
        (ng (eq next conn))
        (ok (= (conn-disconnect-count conn) 1))
        (sleep 0.4)
        (ok (= (conn-disconnect-count conn) 1) "The unscheduled timer does not disconnect again")
        (ok (= (conn-disconnect-count next) 0))
        (putback next pool)
        (ok (= (pool-open-count pool) 1))
        (ok (= (pool-idle-count pool) 1)))))
  (testing "a timer from an earlier idle period leaves the connection alone"
    (let* ((pool (make-lifetime-pool (make-backend) :max-lifetime 60000 :idle-timeout 100))
           (conn (fetch pool)))
      (install-manual-clock pool)
      (putback conn pool)
      (ok (eq (fetch pool) conn))
      (sleep 0.3)
      (ok (= (conn-disconnect-count conn) 0) "Not disconnected while borrowed")
      (putback conn pool)
      (ok (eq (fetch pool) conn))
      (ok (= (conn-disconnect-count conn) 0))
      (putback conn pool)
      (ok (= (pool-open-count pool) 1))))
  (testing "the idle timer fires while fetch drops the expired connection"
    (let* ((pool (make-lifetime-pool (make-backend) :max-lifetime 1000 :idle-timeout 100))
           (advance (install-manual-clock pool))
           (conn (fetch pool))
           (orig-unschedule (symbol-function 'sb-ext:unschedule-timer)))
      (putback conn pool)
      (funcall advance 5000)
      (let ((next (bt2:join-thread
                   (bt2:make-thread
                    (lambda ()
                      (with-mock-functions ((sb-ext:unschedule-timer (timer)
                                              ;; The idle timer fires meanwhile.
                                              (sleep 0.3)
                                              (funcall orig-unschedule timer)))
                        (fetch pool)))))))
        (ng (eq next conn))
        (ok (= (conn-disconnect-count conn) 1) "Disconnected exactly once")
        (ok (= (pool-timeout-in-queue-count pool) 0))
        (ok (= (pool-active-count pool) 1))
        (ok (= (pool-idle-count pool) 0))
        (ok (= (tracked-count pool) 1))))))

#+sbcl
(deftest max-lifetime-expiry-on-putback-wakes-waiter
  (dolist (disconnector (list #'disconnect
                              nil
                              (lambda (conn)
                                (disconnect conn)
                                (error "disconnect failed"))))
    (dolist (args *variants*)
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 1000
                          :max-open-count 1
                          :timeout 2000
                          :disconnector disconnector
                          args))
             (advance (install-manual-clock pool))
             (conn (fetch pool))
             (waiter (start-waiting-fetch (lambda () (fetch pool)) (pool-lock pool))))
        (funcall advance 5000)
        (putback conn pool)
        (let ((result (bt2:join-thread waiter)))
          (ok (eq (first result) :ok) "The waiter is woken")
          (ok (and (conn-p (second result))
                   (not (eq (second result) conn)))
              "The waiter gets a new connection"))
        (ok (= (pool-active-count pool) 1))
        (ok (= (tracked-count pool) 1))))))

(deftest max-lifetime-under-concurrency
  (dolist (args (list '() #+sbcl '(:idle-timeout 1)))
    (let* ((backend (make-backend))
           (connect (backend-connector backend))
           (max-open 3)
           (stat-lock (bt2:make-lock :name "stats"))
           (live 0)
           (max-live 0)
           (double-disconnects 0)
           (lent (make-hash-table :test 'eq))
           (double-lends 0)
           (negative-counts 0)
           (errors '())
           (clock-lock (bt2:make-lock :name "clock"))
           (now 0)
           (pool (apply #'make-pool
                        :connector (lambda ()
                                     (let ((conn (funcall connect)))
                                       (bt2:with-lock-held (stat-lock)
                                         (setf max-live (max max-live (incf live))))
                                       conn))
                        :disconnector (lambda (conn)
                                        (bt2:with-lock-held (stat-lock)
                                          (decf live)
                                          (when (> (incf (conn-disconnect-count conn)) 1)
                                            (incf double-disconnects))))
                        :max-open-count max-open
                        :max-idle-count max-open
                        :timeout 10000
                        ;; Every clock reading is one tick; connections live 20 ticks.
                        :max-lifetime (/ (* 20 1000) internal-time-units-per-second)
                        args)))
      (setf (pool-clock pool)
            (lambda () (bt2:with-lock-held (clock-lock) (incf now))))
      (let ((threads
              (loop repeat 8
                    collect (bt2:make-thread
                             (lambda ()
                               (let ((*random-state* (make-random-state t)))
                                 (handler-case
                                     (loop repeat 2000
                                           do (let ((conn (fetch pool)))
                                                (bt2:with-lock-held (stat-lock)
                                                  (if (gethash conn lent)
                                                      (incf double-lends)
                                                      (setf (gethash conn lent) t))
                                                  (when (or (minusp (pool-active-count pool))
                                                            (minusp (pool-idle-count pool)))
                                                    (incf negative-counts)))
                                                (when (zerop (random 4))
                                                  (bt2:thread-yield))
                                                (bt2:with-lock-held (stat-lock)
                                                  (remhash conn lent))
                                                (putback conn pool)))
                                   (error (e)
                                     (bt2:with-lock-held (stat-lock)
                                       (push e errors))))))))))
        (mapc #'bt2:join-thread threads))
      (when (getf args :idle-timeout)
        (sleep 0.2))
      (ok (null errors) (format nil "No errors: ~S" errors))
      (ok (= double-lends 0) "No connection lent to two borrowers at once")
      (ok (= double-disconnects 0) "No connection disconnected twice")
      (ok (= negative-counts 0))
      (ok (> (backend-created-count backend) max-open) "Connections were replaced")
      (ok (= (pool-active-count pool) 0))
      (ok (= (pool-open-count pool) (pool-idle-count pool)))
      (ok (= live (pool-open-count pool)) "Every discarded connection was disconnected")
      (ok (= (tracked-count pool) (pool-open-count pool)))
      ;; The idle timer disconnects outside the pool lock, so only without it is the
      ;; number of physical connections bounded at every instant.
      (unless (getf args :idle-timeout)
        (ok (<= max-live max-open) "Never more physical connections than max-open-count")))))

(deftest max-lifetime-callback-errors
  (testing "a failing connector leaves nothing behind"
    (let* ((failing t)
           (connect (backend-connector (make-backend)))
           (pool (make-pool :connector (lambda ()
                                         (if failing
                                             (error "connect failed")
                                             (funcall connect)))
                            :max-lifetime 1000)))
      (ok (signals (fetch pool) 'simple-error))
      (ok (= (pool-open-count pool) 0))
      (ok (= (tracked-count pool) 0))
      (setf failing nil)
      (ok (conn-p (fetch pool)))
      (ok (= (tracked-count pool) 1))))
  (testing "a connector returning an object already in the pool is refused"
    (let* ((shared (make-conn :id 0))
           (pool (make-pool :connector (constantly shared)
                            :disconnector #'disconnect
                            :max-lifetime 1000)))
      (ok (eq (fetch pool) shared))
      (ok (signals (fetch pool) 'error))
      (ok (= (conn-disconnect-count shared) 0) "The borrowed one is left alone")
      (ok (= (pool-active-count pool) 1))
      (ok (= (tracked-count pool) 1))))
  (testing "a failing disconnector on an expired connection"
    (dolist (args *variants*)
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 1000
                          :disconnector (lambda (conn)
                                          (disconnect conn)
                                          (error "disconnect failed"))
                          args))
             (advance (install-manual-clock pool))
             (conn (fetch pool)))
        (funcall advance 5000)
        (ok (eq (progn (putback conn pool) :returned) :returned) "putback returns normally")
        (ok (= (conn-disconnect-count conn) 1))
        (ok (= (pool-open-count pool) 0))
        (ok (= (tracked-count pool) 0))
        (let ((conn (fetch pool)))
          (putback conn pool)
          (funcall advance 5000)
          (let ((next (fetch pool)))
            (ng (eq next conn) "fetch moves on to a new connection")
            (ok (= (conn-disconnect-count conn) 1))
            (ok (= (pool-open-count pool) 1))
            (ok (= (tracked-count pool) 1))))))))

(deftest max-lifetime-bookkeeping-cleared
  (dolist (args *variants*)
    (testing "ping failure"
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 60000
                          :ping (lambda (conn) (/= (conn-id conn) 1))
                          args))
             (conn (fetch pool)))
        (install-manual-clock pool)
        (putback conn pool)
        (ng (eq (fetch pool) conn))
        (ok (= (conn-disconnect-count conn) 1))
        (ok (= (tracked-count pool) 1))))
    (testing "full idle queue"
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 60000 :max-open-count 2 :max-idle-count 1 args))
             (a (fetch pool))
             (b (fetch pool)))
        (install-manual-clock pool)
        (putback a pool)
        (putback b pool)
        (ok (= (conn-disconnect-count b) 1))
        (ok (= (tracked-count pool) 1))
        (ok (= (pool-open-count pool) 1))))
    (testing "max-idle-count 0"
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 60000 :max-idle-count 0 args))
             (conn (fetch pool)))
        (install-manual-clock pool)
        (putback conn pool)
        (ok (= (conn-disconnect-count conn) 1))
        (ok (= (tracked-count pool) 0))
        (ok (= (pool-open-count pool) 0))))
    (testing "no disconnector"
      (let* ((pool (apply #'make-lifetime-pool (make-backend)
                          :max-lifetime 1000 :disconnector nil args))
             (advance (install-manual-clock pool))
             (borrowed (fetch pool))
             (idle (fetch pool)))
        (putback idle pool)
        (funcall advance 5000)
        (putback borrowed pool)
        (ok (= (tracked-count pool) 1) "The expired borrowed one is dropped on putback")
        (ng (eq (fetch pool) idle))
        (ok (= (tracked-count pool) 1) "The expired idle one is dropped on fetch")
        (ok (= (pool-open-count pool) 1))))))

(deftest max-lifetime-with-unlimited-open-count
  (dolist (args *variants*)
    (let* ((backend (make-backend))
           (pool (apply #'make-lifetime-pool backend
                        :max-lifetime 1000 :max-open-count nil :max-idle-count 2 args))
           (advance (install-manual-clock pool))
           (conns (loop repeat 10 collect (fetch pool))))
      (funcall advance 5000)
      (dolist (conn conns)
        (putback conn pool))
      (ok (every (lambda (conn) (= (conn-disconnect-count conn) 1)) conns))
      (ok (= (pool-open-count pool) 0))
      (ok (= (tracked-count pool) 0))
      (ok (= (conn-id (fetch pool)) 11)))))

(deftest max-lifetime-reconnects-to-new-target
  (dolist (args *variants*)
    (let* ((backend (make-backend :target :a))
           (pool (apply #'make-lifetime-pool backend
                        :max-lifetime 1000 :ping (constantly t) args))
           (advance (install-manual-clock pool))
           (old (fetch pool)))
      (putback old pool)
      (setf (backend-target backend) :b)
      (funcall advance 500)
      (let ((conn (fetch pool)))
        (ok (eq conn old) "The healthy connection to A is kept until it expires")
        (putback conn pool))
      (funcall advance 500)
      (let ((conn (fetch pool)))
        (ok (eq (conn-target conn) :b) "The connector runs again and reaches B")
        (ok (= (conn-disconnect-count old) 1))
        (putback conn pool)))))
