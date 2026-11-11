(defpackage #:anypool/tests/io-outside-lock
  (:use #:cl
        #:rove
        #:anypool)
  (:import-from #:anypool
                #:pool-clock
                #:pool-created-at-table
                #:pool-lock
                #:without-interrupts*
                #:with-local-interrupts*)
  (:import-from #:anypool/tests/utils
                #:with-mock-functions
                #:start-waiting-fetch))

(in-package #:anypool/tests/io-outside-lock)

;;; A gate stops a callback (connector, ping, disconnector) at a known point, so a test can act on
;;; the pool while that callback is in progress.
(defstruct (gate (:constructor make-gate ()))
  (entered (bt2:make-semaphore :name "gate entered"))
  (release (bt2:make-semaphore :name "gate release")))

(defun pass-gate (gate)
  (bt2:signal-semaphore (gate-entered gate))
  (bt2:wait-on-semaphore (gate-release gate)))

(defun await-gate (gate)
  (or (bt2:wait-on-semaphore (gate-entered gate) :timeout 5)
      (error "Nothing reached the gate")))

(defun open-gate (gate &optional (count 1))
  (bt2:signal-semaphore (gate-release gate) :count count))

(defun make-counter ()
  (let ((n 0)
        (lock (bt2:make-lock :name "counter")))
    (lambda ()
      (bt2:with-lock-held (lock)
        (incf n)))))

(defun spawn (fn)
  (bt2:make-thread (lambda ()
                     (handler-case (list :ok (funcall fn))
                       (error (e) (list :error e))))))

(defun join-within (thread seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (unless (bt2:thread-alive-p thread)
        (return (values t (bt2:join-thread thread))))
      (when (> (get-internal-real-time) deadline)
        (return (values nil nil)))
      (sleep 0.01))))

(defun call-within (seconds fn)
  (multiple-value-bind (finished result) (join-within (spawn fn) seconds)
    (values finished
            (and finished
                 (if (eq (first result) :ok)
                     (second result)
                     (error (second result)))))))

(define-condition interrupted (error) ())

(defun interrupt (thread)
  (bt2:interrupt-thread thread (lambda () (error 'interrupted))))

(defun interrupted-p (result)
  (and (eq (first result) :error)
       (typep (second result) 'interrupted)))

(defun interrupt-with-throw (thread)
  "Interrupt THREAD by throwing to its INTERRUPT-EXIT catch. Unlike INTERRUPT's error, no IGNORE-ERRORS
in the pool can swallow it."
  (bt2:interrupt-thread thread (lambda () (throw 'interrupt-exit :thrown))))

#+sbcl
(defun await-blocked-on (thread lock)
  "Wait until THREAD is blocked taking LOCK."
  ;; Looked up at run time: read as a literal, a renamed SBCL internal would stop the whole file
  ;; from loading instead of failing only the tests that use it.
  (let ((waiting-for (let ((symbol (find-symbol "THREAD-WAITING-FOR" "SB-THREAD")))
                       (if (and symbol (fboundp symbol))
                           symbol
                           (error "SB-THREAD::THREAD-WAITING-FOR is not available in this SBCL"))))
        (native-thread (bt2:thread-native-thread thread))
        (mutex (bt2:lock-native-lock lock)))
    (or (loop repeat 500
              thereis (eq (funcall waiting-for native-thread) mutex)
              do (sleep 0.01))
        (error "The thread never blocked on the lock"))))

#+sbcl
(deftest putback-interrupted-while-disconnecting-releases-slot
  (let* ((gate (make-gate))
         (pool (make-pool :connector (make-counter)
                          :disconnector (lambda (conn)
                                          (declare (ignore conn))
                                          (pass-gate gate))
                          :max-open-count 1
                          :max-idle-count 0
                          :timeout 2000))
         (conn (fetch pool))
         (returning (spawn (lambda () (putback conn pool)))))
    (await-gate gate)
    (let ((waiter (start-waiting-fetch (lambda () (fetch pool)) (pool-lock pool))))
      (interrupt returning)
      (multiple-value-bind (finished result) (join-within returning 2)
        (unless finished
          (open-gate gate))
        (ok finished "The disconnect can still be interrupted")
        (ok (and finished (interrupted-p result))))
      (let ((result (bt2:join-thread waiter)))
        (ok (eq (first result) :ok) "The slot is released and the waiter woken")
        (ok (eql (second result) 2))))))

(deftest connect-does-not-block-other-borrowers
  (let* ((gate (make-gate))
         (blocking nil)
         (next-id (make-counter))
         (pool (make-pool :connector (lambda ()
                                       (when blocking
                                         (pass-gate gate))
                                       (funcall next-id))
                          :max-open-count 3)))
    (let ((a (fetch pool)))
      (fetch pool)
      (setf blocking t)
      (let ((connecting (spawn (lambda () (fetch pool)))))
        (await-gate gate)
        (ok (call-within 1 (lambda () (putback a pool)))
            "putback does not wait for the connect")
        (multiple-value-bind (finished conn) (call-within 1 (lambda () (fetch pool)))
          (ok finished "An idle connection is lent meanwhile")
          (ok (eql conn a)))
        (open-gate gate)
        (ok (equal (bt2:join-thread connecting) '(:ok 3)))
        (ok (= (pool-active-count pool) 3))))))

(deftest ping-does-not-block-other-borrowers
  (let* ((gate (make-gate))
         (blocked nil)
         (pool (make-pool :connector (make-counter)
                          :ping (lambda (conn)
                                  (when (eql conn blocked)
                                    (pass-gate gate))
                                  t)
                          :max-open-count 3)))
    (let ((a (fetch pool))
          (b (fetch pool)))
      (putback a pool)
      (setf blocked a)
      (let ((pinging (spawn (lambda () (fetch pool)))))
        (await-gate gate)
        (ok (call-within 1 (lambda () (putback b pool)))
            "putback does not wait for the ping")
        (multiple-value-bind (finished conn) (call-within 1 (lambda () (fetch pool)))
          (ok finished "Another idle connection is lent meanwhile")
          (ok (eql conn b)))
        (open-gate gate)
        (ok (equal (bt2:join-thread pinging) (list :ok a)))))))

(deftest waiting-for-a-connecting-slot-times-out
  (let* ((gate (make-gate))
         (pool (make-pool :connector (lambda () (pass-gate gate) :conn)
                          :max-open-count 1
                          :timeout 200)))
    (let ((connecting (spawn (lambda () (fetch pool)))))
      (await-gate gate)
      (multiple-value-bind (finished result)
          (call-within 2 (lambda ()
                           (handler-case (fetch pool)
                             (too-many-open-connection () :too-many))))
        (ok finished "The waiter is not stuck behind the connect")
        (ok (eq result :too-many)))
      (open-gate gate)
      (ok (equal (bt2:join-thread connecting) '(:ok :conn))))))

(deftest too-many-open-connection-is-signalled-without-the-pool-lock
  (dolist (timeout '(50 0))
    (let* ((pool (make-pool :connector (make-counter)
                            :max-open-count 1
                            :timeout timeout))
           (lock (pool-lock pool))
           (handled nil)
           (lock-free nil))
      (fetch pool)
      (multiple-value-bind (finished result)
          (call-within 5 (lambda ()
                           (handler-case
                               (handler-bind ((too-many-open-connection
                                                (lambda (c)
                                                  (declare (ignore c))
                                                  (setf handled t)
                                                  (when (ignore-errors (bt2:acquire-lock lock :wait nil))
                                                    (bt2:release-lock lock)
                                                    (setf lock-free t)))))
                                 (fetch pool))
                             (too-many-open-connection () :too-many))))
        (ok finished)
        (ok (eq result :too-many))
        (ok handled)
        (ok lock-free (format nil "The pool lock is free in the handler (timeout ~A)" timeout)))
      (ok (= (pool-active-count pool) 1)))))

(deftest connects-in-flight-count-toward-max-open
  (let* ((gate (make-gate))
         (next-id (make-counter))
         (pool (make-pool :connector (lambda ()
                                       (pass-gate gate)
                                       (funcall next-id))
                          :max-open-count 2
                          :timeout 300))
         (threads (loop repeat 4 collect (spawn (lambda () (fetch pool))))))
    (await-gate gate)
    (await-gate gate)
    (ng (bt2:wait-on-semaphore (gate-entered gate) :timeout 0.5) "No third connect starts")
    (open-gate gate 4)
    (let ((results (mapcar #'bt2:join-thread threads)))
      (ok (= (count :ok results :key #'first) 2))
      (ok (every (lambda (result)
                   (or (eq (first result) :ok)
                       (typep (second result) 'too-many-open-connection)))
                 results)))))

#+sbcl
(deftest connector-error-releases-slot-and-wakes-waiter
  (let* ((gate (make-gate))
         (calls (make-counter))
         (pool (make-pool :connector (lambda ()
                                       (let ((n (funcall calls)))
                                         (when (= n 1)
                                           (pass-gate gate)
                                           (error "connect failed"))
                                         n))
                          :max-open-count 1
                          :timeout 2000)))
    (let ((failing (spawn (lambda () (fetch pool)))))
      (await-gate gate)
      (let ((waiter (start-waiting-fetch (lambda () (fetch pool)) (pool-lock pool))))
        (open-gate gate)
        (ok (eq (first (bt2:join-thread failing)) :error))
        (let ((result (bt2:join-thread waiter)))
          (ok (eq (first result) :ok) "The waiter is woken and opens a new connection")
          (ok (eql (second result) 2)))
        (ok (= (pool-active-count pool) 1))))))

(deftest retired-connection-slot-is-reused-without-waiting
  (let* ((disconnected '())
         (pool (make-pool :connector (make-counter)
                          :disconnector (lambda (conn) (push conn disconnected))
                          :ping (lambda (conn) (/= conn 1))
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (ok (eql (fetch pool) 2) "The slot of the retired connection opens the replacement")
    (ok (equal disconnected '(1)))
    (ok (= (pool-active-count pool) 1))
    (ok (= (pool-idle-count pool) 0))))

(deftest replacement-connect-failure-releases-slot
  (let* ((calls (make-counter))
         (pool (make-pool :connector (lambda ()
                                       (let ((n (funcall calls)))
                                         (if (= n 2)
                                             (error "connect failed")
                                             n)))
                          :ping (constantly nil)
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (ok (signals (fetch pool) 'simple-error))
    (ok (= (pool-active-count pool) 0))
    (ok (= (pool-open-count pool) 0))
    (ok (eql (fetch pool) 3) "The slot can be used again")))

(define-condition connect-progress (condition) ())

(deftest non-local-exit-from-connector-releases-slot
  (let ((pool (make-pool :connector (lambda ()
                                      (signal 'connect-progress)
                                      :conn)
                         :max-open-count 1
                         :timeout 0)))
    (ok (eq (block abort
              (handler-bind ((connect-progress (lambda (c)
                                                 (declare (ignore c))
                                                 (return-from abort :aborted))))
                (fetch pool)))
            :aborted))
    (ok (= (pool-active-count pool) 0))
    (ok (eq (fetch pool) :conn) "The slot is free again")))

(deftest non-local-exit-from-disconnector-in-cleanup-releases-slot
  (let* ((pool (make-pool :connector (make-counter)
                          :disconnector (lambda (conn)
                                          (declare (ignore conn))
                                          (throw 'disconnecting :thrown))
                          :ping (lambda (conn)
                                  (declare (ignore conn))
                                  (error "ping failed"))
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (ok (eq (catch 'disconnecting
              (handler-case (fetch pool)
                (error () :ping-error)))
            :thrown)
        "The cleanup retires the connection being pinged")
    (ok (= (pool-active-count pool) 0) "The slot is released")
    (ok (eql (handler-case (fetch pool)
               (too-many-open-connection () :too-many))
             2)
        "The slot can be used again")))

#+sbcl
(deftest interrupt-during-connect-releases-slot
  (let* ((gate (make-gate))
         (calls (make-counter))
         (pool (make-pool :connector (lambda ()
                                       (let ((n (funcall calls)))
                                         (when (= n 1)
                                           (pass-gate gate))
                                         n))
                          :max-open-count 1
                          :timeout 2000)))
    (let ((connecting (spawn (lambda () (fetch pool)))))
      (await-gate gate)
      (let ((waiter (start-waiting-fetch (lambda () (fetch pool)) (pool-lock pool))))
        (interrupt connecting)
        (multiple-value-bind (finished result) (join-within connecting 2)
          (unless finished
            (open-gate gate))
          (ok (and finished (interrupted-p result)) "The connect can be interrupted"))
        (let ((result (bt2:join-thread waiter)))
          (ok (eq (first result) :ok) "The waiter is woken")
          (ok (eql (second result) 2)))
        (ok (= (pool-active-count pool) 1))))))

#+sbcl
(deftest interrupt-during-ping-retires-connection-and-releases-slot
  (dolist (args (list '() #+sbcl '(:idle-timeout 600000)))
    (let* ((gate (make-gate))
           (disconnected '())
           (pinging-enabled nil)
           (pool (apply #'make-pool
                        :connector (make-counter)
                        :disconnector (lambda (conn) (push conn disconnected))
                        :ping (lambda (conn)
                                (declare (ignore conn))
                                (when pinging-enabled
                                  (pass-gate gate))
                                t)
                        :max-open-count 1
                        :timeout 2000
                        args)))
      (putback (fetch pool) pool)
      (setf pinging-enabled t)
      (let ((pinging (spawn (lambda () (fetch pool)))))
        (await-gate gate)
        (let ((waiter (start-waiting-fetch (lambda () (fetch pool)) (pool-lock pool))))
          (interrupt pinging)
          (multiple-value-bind (finished result) (join-within pinging 2)
            (unless finished
              (open-gate gate))
            (ok (and finished (interrupted-p result)) "The ping can be interrupted"))
          (ok (equal disconnected '(1)) "The connection being pinged is disconnected")
          (let ((result (bt2:join-thread waiter)))
            (ok (eq (first result) :ok) "The waiter is woken")
            (ok (eql (second result) 2))))))))

#+sbcl
(deftest interrupt-during-cleanup-disconnect-releases-slot
  (dolist (args (list '() #+sbcl '(:idle-timeout 600000)))
    (let* ((gate (make-gate))
           (failing nil)
           (pool (apply #'make-pool
                        :connector (make-counter)
                        :disconnector (lambda (conn)
                                        (declare (ignore conn))
                                        (when failing
                                          (pass-gate gate)))
                        :ping (lambda (conn)
                                (declare (ignore conn))
                                (when failing
                                  (error "ping failed"))
                                t)
                        :max-open-count 1
                        :timeout 0
                        args)))
      (putback (fetch pool) pool)
      (setf failing t)
      (let ((fetching (bt2:make-thread
                       (lambda ()
                         (catch 'interrupt-exit
                           (handler-case (fetch pool)
                             (error () :ping-error)))))))
        (await-gate gate)
        (interrupt-with-throw fetching)
        (multiple-value-bind (finished result) (join-within fetching 2)
          (unless finished
            (open-gate gate 2)
            (ok (join-within fetching 5) "The thread finishes once the gate opens"))
          (ok finished "The disconnect in the cleanup can be interrupted")
          (ok (and finished (eq result :thrown)) "The interrupt exits through the disconnect"))
        (ok (= (pool-active-count pool) 0) "The slot is released")
        (setf failing nil)
        (ok (eql (handler-case (fetch pool)
                   (too-many-open-connection () :too-many))
                 2)
            "The slot can be used again")))))

#+sbcl
(deftest timeout-while-disconnecting-a-rejected-connection-stops-fetch
  (let* ((gate (make-gate))
         (rejecting nil)
         (pool (make-pool :connector (make-counter)
                          :disconnector (lambda (conn)
                                          (declare (ignore conn))
                                          (when rejecting
                                            (pass-gate gate)))
                          :ping (lambda (conn)
                                  (declare (ignore conn))
                                  (not rejecting))
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (setf rejecting t)
    (let ((fetching (spawn (lambda ()
                             (handler-case (sb-ext:with-timeout 0.5 (fetch pool))
                               (sb-ext:timeout () :timed-out))))))
      (await-gate gate)
      (multiple-value-bind (finished result) (join-within fetching 3)
        (unless finished
          (open-gate gate 2)
          (ok (join-within fetching 5) "The thread finishes once the gate opens"))
        (ok (and finished (equal result '(:ok :timed-out)))
            "fetch stops instead of opening a replacement"))
      (ok (= (pool-active-count pool) 0) "The slot is released")
      (setf rejecting nil)
      (ok (eql (handler-case (fetch pool)
                 (too-many-open-connection () :too-many))
               2)
          "The slot can be used again"))))

(define-condition ping-failure (error) ())

#+sbcl
(defun deferring-failing-disconnector (record)
  "A disconnector that fails while deferring interrupts itself, as one protecting its own cleanup may."
  (lambda (conn)
    (funcall record conn)
    (sb-sys:without-interrupts
      (error "disconnect failed"))))

#+sbcl
(deftest disconnect-error-with-interrupts-deferred-is-ignored-after-a-rejected-ping
  (let* ((disconnected '())
         (rejecting nil)
         (pool (make-pool :connector (make-counter)
                          :disconnector (deferring-failing-disconnector
                                         (lambda (conn) (push conn disconnected)))
                          :ping (lambda (conn)
                                  (declare (ignore conn))
                                  (not rejecting))
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (setf rejecting t)
    (ok (eql (handler-case (fetch pool)
               (error (e) e))
             2)
        "The replacement is returned")
    (ok (equal disconnected '(1)) "The rejected connection is disconnected")
    (ok (= (pool-active-count pool) 1))
    (ok (= (pool-idle-count pool) 0))
    (ok (= (pool-open-count pool) 1))))

#+sbcl
(deftest disconnect-error-with-interrupts-deferred-does-not-replace-the-ping-error
  (let* ((disconnected '())
         (failing nil)
         (pool (make-pool :connector (make-counter)
                          :disconnector (deferring-failing-disconnector
                                         (lambda (conn) (push conn disconnected)))
                          :ping (lambda (conn)
                                  (declare (ignore conn))
                                  (when failing
                                    (error 'ping-failure))
                                  t)
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (setf failing t)
    (ok (eq (handler-case (fetch pool)
              (ping-failure () :ping-failure)
              (error (e) e))
            :ping-failure)
        "The ping error propagates")
    (ok (equal disconnected '(1)) "The connection being pinged is disconnected")
    (ok (= (pool-active-count pool) 0) "The slot is released")
    (setf failing nil)
    (ok (eql (handler-case (fetch pool)
               (too-many-open-connection () :too-many))
             2)
        "The slot can be used again")))

#+sbcl
(deftest disconnect-error-with-interrupts-deferred-is-ignored-for-an-expired-connection
  (let* ((disconnected '())
         (pool (make-pool :connector (make-counter)
                          :disconnector (deferring-failing-disconnector
                                         (lambda (conn) (push conn disconnected)))
                          :max-lifetime 1000))
         (now 0))
    (setf (pool-clock pool) (lambda () now))
    (let ((conn (fetch pool)))
      (setf now (* 5 internal-time-units-per-second))
      (ok (eq (handler-case (progn (putback conn pool) :returned)
                (error (e) e))
              :returned)
          "putback returns normally"))
    (ok (equal disconnected '(1)) "The expired connection is disconnected")
    (ok (= (pool-active-count pool) 0) "The slot is released")
    (ok (= (pool-open-count pool) 0))
    (ok (= (hash-table-count (pool-created-at-table pool)) 0))))

#+sbcl
(deftest with-connection-returns-connection-when-body-is-interrupted
  (let* ((gate (make-gate))
         (pool (make-pool :connector (make-counter)))
         (thread (spawn (lambda ()
                          (with-connection (conn pool)
                            (pass-gate gate)
                            conn)))))
    (await-gate gate)
    (interrupt thread)
    (multiple-value-bind (finished result) (join-within thread 2)
      (unless finished
        (open-gate gate))
      (ok (and finished (interrupted-p result))))
    (ok (= (pool-active-count pool) 0))
    (ok (= (pool-idle-count pool) 1) "The connection is put back")))

#+sbcl
(deftest with-connection-lets-fetch-be-interrupted
  (let* ((gate (make-gate))
         (pool (make-pool :connector (lambda () (pass-gate gate) :conn)
                          :max-open-count 1))
         (thread (spawn (lambda ()
                          (with-connection (conn pool)
                            conn)))))
    (await-gate gate)
    (interrupt thread)
    (multiple-value-bind (finished result) (join-within thread 2)
      (unless finished
        (open-gate gate))
      (ok finished "The connect inside with-connection can be interrupted")
      (ok (and finished (interrupted-p result))))
    (ok (= (pool-active-count pool) 0))
    (ok (= (pool-idle-count pool) 0))))

#+sbcl
(deftest waiting-fetch-hands-over-the-pool-lock-with-interrupts-deferred
  (let* ((pool (make-pool :connector (make-counter)
                          :max-open-count 1
                          :timeout 2000))
         (lock (pool-lock pool))
         (conn (fetch pool))
         (orig-release (symbol-function 'bt2:release-lock))
         (orig-acquire (symbol-function 'bt2:acquire-lock))
         (record-lock (bt2:make-lock :name "record"))
         (released (bt2:make-semaphore))
         (waiter nil)
         (recorded '()))
    (flet ((record (op l)
             (when (and (eq l lock) (eq (bt2:current-thread) waiter))
               ;; Read before taking RECORD-LOCK, whose body re-enables interrupts where allowed.
               (let ((enabled sb-sys:*interrupts-enabled*))
                 (bt2:with-lock-held (record-lock)
                   (push (cons op enabled) recorded))))))
      (with-mock-functions ((bt2:release-lock (l)
                              (record :release l)
                              (prog1 (funcall orig-release l)
                                (when (and (eq l lock) (eq (bt2:current-thread) waiter))
                                  (bt2:signal-semaphore released))))
                            (bt2:acquire-lock (l &rest args)
                              (record :acquire l)
                              (apply orig-acquire l args)))
        (let ((thread (spawn (lambda ()
                               (setf waiter (bt2:current-thread))
                               (fetch pool)))))
          (ok (bt2:wait-on-semaphore released :timeout 5) "The fetch waits for a slot")
          (putback conn pool)
          (multiple-value-bind (finished result) (join-within thread 3)
            (ok (and finished (equal result (list :ok conn))) "The waiter gets the connection")))))
    (ok (find :release recorded :key #'car))
    (ok (find :acquire recorded :key #'car))
    (ok (notany #'cdr recorded)
        (format nil "The pool lock is released and taken again with interrupts deferred: ~S"
                (reverse recorded)))))

#+sbcl
(deftest interrupted-waiter-leaves-the-pool-usable
  (let* ((pool (make-pool :connector (make-counter)
                          :max-open-count 1
                          :timeout 2000))
         (conn (fetch pool))
         (waiter (start-waiting-fetch (lambda () (fetch pool)) (pool-lock pool))))
    (interrupt waiter)
    (multiple-value-bind (finished result) (join-within waiter 1)
      (ok (and finished (interrupted-p result)) "The waiting fetch is interrupted before its timeout"))
    (ok (= (pool-active-count pool) 1) "Only the held connection is counted")
    (multiple-value-bind (finished result)
        (call-within 2 (lambda ()
                         (putback conn pool)
                         (let ((again (fetch pool)))
                           (putback again pool)
                           again)))
      (ok finished "The pool lock is not left taken")
      (ok (eql result conn)))
    (ok (= (pool-active-count pool) 0))
    (ok (= (pool-idle-count pool) 1))))

#+sbcl
(deftest interrupt-while-retiring-a-rejected-connection-forgets-it
  (let* ((pinged (bt2:make-semaphore))
         (locked (bt2:make-semaphore))
         (rejecting nil)
         (disconnects (make-hash-table))
         (pool (make-pool :connector (make-counter)
                          :disconnector (lambda (conn) (incf (gethash conn disconnects 0)))
                          ;; Returns only once the test holds the pool lock, so the fetch blocks
                          ;; taking it to retire the connection.
                          :ping (lambda (conn)
                                  (declare (ignore conn))
                                  (cond
                                    (rejecting
                                     (bt2:signal-semaphore pinged)
                                     (bt2:wait-on-semaphore locked :timeout 5)
                                     nil)
                                    (t t)))
                          :max-open-count 1
                          :timeout 0
                          :max-lifetime 600000))
         (lock (pool-lock pool)))
    (putback (fetch pool) pool)
    (setf rejecting t)
    (let ((fetching (spawn (lambda () (fetch pool)))))
      (ok (bt2:wait-on-semaphore pinged :timeout 5) "The idle connection is pinged")
      (bt2:acquire-lock lock)
      (unwind-protect
           (progn
             (bt2:signal-semaphore locked)
             (await-blocked-on fetching lock)
             (interrupt fetching))
        (bt2:release-lock lock))
      (multiple-value-bind (finished result) (join-within fetching 2)
        (ok (and finished (interrupted-p result)) "The fetch is interrupted while retiring")))
    (ok (= (pool-active-count pool) 0) "The slot is released")
    (ok (= (hash-table-count (pool-created-at-table pool)) (pool-open-count pool))
        "The creation time of the retired connection is forgotten")
    (ok (= (gethash 1 disconnects 0) 1) "The retired connection is disconnected once")))

(deftest fetch-keeps-the-slot-while-disconnecting-a-rejected-connection
  (let* ((gate (make-gate))
         (stat-lock (bt2:make-lock :name "stats"))
         (live 0)
         (max-live 0)
         (next-id (make-counter))
         (rejected nil)
         (pool (make-pool :connector (lambda ()
                                       (let ((id (funcall next-id)))
                                         (bt2:with-lock-held (stat-lock)
                                           (setf max-live (max max-live (incf live))))
                                         id))
                          :disconnector (lambda (conn)
                                          (when (eql conn rejected)
                                            (pass-gate gate))
                                          (bt2:with-lock-held (stat-lock)
                                            (decf live)))
                          :ping (lambda (conn) (not (eql conn rejected)))
                          :max-open-count 1
                          :timeout 0)))
    (putback (fetch pool) pool)
    (setf rejected 1)
    (let ((fetching (spawn (lambda () (fetch pool)))))
      (await-gate gate)
      ;; Opened even if the competing fetch fails otherwise, or FETCHING stays parked in the gate.
      (unwind-protect
           (multiple-value-bind (finished result)
               (call-within 2 (lambda ()
                                (handler-case (fetch pool)
                                  (too-many-open-connection () :too-many))))
             (ok finished)
             (ok (eq result :too-many) "The slot is still counted while the rejected one is disconnected"))
        (open-gate gate))
      (multiple-value-bind (finished result) (join-within fetching 2)
        (ok (and finished (equal result '(:ok 2))) "The fetch opens the replacement in its slot")))
    (ok (= max-live 1) "No more physical connections than max-open-count at any time")
    (ok (= live 1))
    (ok (= (pool-active-count pool) 1))
    (ok (= (pool-idle-count pool) 0))))

#+sbcl
(deftest woken-waiter-that-loses-the-race-waits-again
  (let* ((pool (make-pool :connector (make-counter)
                          :max-open-count 1
                          :timeout 2000))
         (lock (pool-lock pool))
         (conn (fetch pool))
         (orig-release (symbol-function 'bt2:release-lock))
         (orig-acquire (symbol-function 'bt2:acquire-lock))
         (released (bt2:make-semaphore))
         (regrabbing (bt2:make-semaphore))
         (resume (bt2:make-semaphore))
         ;; Signalled only by a wait that follows the held re-grab, so a release from a spurious
         ;; wakeup before that cannot pass for waiting again.
         (released-again (bt2:make-semaphore))
         (armed nil)
         (regrabbed nil)
         (waiter nil))
    ;; The woken waiter is held before it takes the pool lock again, so a competing fetch reliably
    ;; takes the connection first.
    (with-mock-functions ((bt2:release-lock (l)
                            (prog1 (funcall orig-release l)
                              (when (and (eq l lock) (eq (bt2:current-thread) waiter))
                                (bt2:signal-semaphore (if regrabbed released-again released)))))
                          (bt2:acquire-lock (l &rest args)
                            (when (and armed (eq l lock) (eq (bt2:current-thread) waiter))
                              (setf armed nil)
                              (bt2:signal-semaphore regrabbing)
                              (bt2:wait-on-semaphore resume :timeout 5)
                              (setf regrabbed t))
                            (apply orig-acquire l args)))
      (let ((thread (spawn (lambda ()
                             (setf waiter (bt2:current-thread))
                             (fetch pool)))))
        (ok (bt2:wait-on-semaphore released :timeout 5) "The fetch waits for a slot")
        (setf armed t)
        (putback conn pool)
        (ok (bt2:wait-on-semaphore regrabbing :timeout 5) "The putback wakes the waiter")
        (multiple-value-bind (finished taken)
            (unwind-protect (call-within 2 (lambda () (fetch pool)))
              (bt2:signal-semaphore resume))
          (ok (and finished (eql taken conn)) "A competing fetch takes the connection first")
          (ok (bt2:wait-on-semaphore released-again :timeout 5) "The waiter waits again")
          (ok (bt2:thread-alive-p thread) "The waiter has not returned")
          (when finished
            (putback taken pool)))
        (multiple-value-bind (finished result) (join-within thread 3)
          (ok (and finished (equal result (list :ok conn)))
              "The waiter gets the connection once it is put back again"))))
    (ok (= (pool-active-count pool) 1) "No connection is opened beyond max-open-count")))

(deftest rejected-idle-connections-share-one-slot
  (dolist (args (list '() #+sbcl '(:idle-timeout 600000)))
    (let* ((disconnected '())
           (rejecting nil)
           (pool (apply #'make-pool
                        :connector (make-counter)
                        :disconnector (lambda (conn) (push conn disconnected))
                        :ping (lambda (conn)
                                (declare (ignore conn))
                                (not rejecting))
                        :max-open-count 3
                        :max-idle-count 3
                        :timeout 0
                        args)))
      (let ((conns (list (fetch pool) (fetch pool) (fetch pool))))
        (dolist (conn conns)
          (putback conn pool)))
      (setf rejecting t)
      (ok (eql (fetch pool) 4) "One new connection replaces all rejected ones")
      (ok (equal (sort disconnected #'<) '(1 2 3)) "Each rejected connection is disconnected once")
      (ok (= (pool-active-count pool) 1))
      (ok (= (pool-idle-count pool) 0))
      (ok (= (pool-open-count pool) 1)))))

#+sbcl
(deftest interrupt-right-after-connect-leaks-only-the-connection
  (let* ((connected (bt2:make-semaphore))
         (locked (bt2:make-semaphore))
         (disconnected '())
         (conn (list :conn))
         ;; Returns only once the test holds the pool lock, so the fetch blocks taking it to
         ;; record the creation time.
         (pool (make-pool :connector (lambda ()
                                       (bt2:signal-semaphore connected)
                                       (bt2:wait-on-semaphore locked :timeout 5)
                                       conn)
                          :disconnector (lambda (c) (push c disconnected))
                          :max-open-count 1
                          :timeout 0
                          :max-lifetime 600000))
         (lock (pool-lock pool))
         (fetching (spawn (lambda () (fetch pool)))))
    (ok (bt2:wait-on-semaphore connected :timeout 5) "The connector runs")
    (bt2:acquire-lock lock)
    (unwind-protect
         (progn
           (bt2:signal-semaphore locked)
           (await-blocked-on fetching lock)
           (interrupt fetching))
      (bt2:release-lock lock))
    (multiple-value-bind (finished result) (join-within fetching 2)
      (ok (and finished (interrupted-p result)) "The fetch is interrupted before taking the connection"))
    (ok (= (pool-active-count pool) 0) "The slot is released")
    (ok (= (hash-table-count (pool-created-at-table pool)) (pool-open-count pool) 0)
        "No creation time is left for the connection")
    (ok (null disconnected) "The physical connection leaks, as documented")))

(deftest with-connection-puts-back-on-non-local-exit
  (let ((pool (make-pool :connector (make-counter))))
    (ok (eql (block body
               (with-connection (conn pool)
                 (return-from body conn)))
             1))
    (ok (= (pool-active-count pool) 0))
    (ok (= (pool-idle-count pool) 1) "The connection is put back")))

(deftest with-connection-returns-all-values-of-the-body
  (let ((pool (make-pool :connector (make-counter))))
    (ok (equal (multiple-value-list (with-connection (conn pool)
                                      (values conn :b :c)))
               '(1 :b :c)))))

(defvar *conn* :outer)

(defun current-conn ()
  *conn*)

(deftest with-connection-binds-a-special-variable
  (let ((pool (make-pool :connector (make-counter))))
    (ok (eql (with-connection (*conn* pool)
               (current-conn))
             1)
        "The body sees the fetched connection through the dynamic binding")
    (ok (eq *conn* :outer) "The outer value is restored")))

#+sbcl
(deftest with-connection-keeps-the-callers-interrupt-state
  (let ((pool (make-pool :connector (make-counter))))
    (ok (eq (with-connection (conn pool)
              sb-sys:*interrupts-enabled*)
            t)
        "Enabled in the body for a normal caller")
    (ok (null (without-interrupts*
                (with-connection (conn pool)
                  sb-sys:*interrupts-enabled*)))
        "Still deferred in the body for a caller that deferred them")))

(deftest with-connection-ignores-a-disconnect-error-for-an-expired-connection
  (let* ((pool (make-pool :connector (make-counter)
                          :disconnector (lambda (conn)
                                          (declare (ignore conn))
                                          (error "disconnect failed"))
                          :max-lifetime 1000))
         (now 0))
    (setf (pool-clock pool) (lambda () now))
    (ok (eq (with-connection (conn pool)
              (setf now (* 5 internal-time-units-per-second))
              :done)
            :done)
        "The body's value is returned")
    (ok (= (pool-active-count pool) 0) "The slot is freed")
    (ok (= (pool-open-count pool) 0))
    (ok (= (hash-table-count (pool-created-at-table pool)) 0))))

(define-condition injected-failure (error) ())

;; Bound to T only where the worker catches INTERRUPTED; an interrupt landing anywhere else in the
;; thread (its start-up, or bt2's wrapper after the body returns) would go unhandled.
(defvar *armed* nil)

#+sbcl
(deftest fetch-survives-failures-and-interrupts-under-concurrency
  (dolist (args (list '() #+sbcl '(:idle-timeout 1)))
    (let* ((stat-lock (bt2:make-lock :name "stats"))
           (live 0)
           (double-disconnects 0)
           (double-lends 0)
           (negative-counts 0)
           (unexpected-errors '())
           (lent (make-hash-table :test 'eq))
           (next-id (make-counter))
           (clock-lock (bt2:make-lock :name "clock"))
           (now 0)
           (interrupts 0)
           (stop nil)
           (pool (apply #'make-pool
                        :connector (lambda ()
                                     (when (zerop (random 20))
                                       (error 'injected-failure))
                                     ;; (id . disconnect-count)
                                     (let ((conn (cons (funcall next-id) 0)))
                                       (bt2:with-lock-held (stat-lock)
                                         (incf live))
                                       conn))
                        :disconnector (lambda (conn)
                                        (bt2:with-lock-held (stat-lock)
                                          (decf live)
                                          (when (> (incf (cdr conn)) 1)
                                            (incf double-disconnects))))
                        :ping (lambda (conn)
                                (declare (ignore conn))
                                (case (random 50)
                                  (0 (error 'injected-failure))
                                  ((1 2) nil)
                                  (t t)))
                        :max-open-count 3
                        :max-idle-count 3
                        :timeout 10000
                        ;; Every clock reading is one tick; connections live 20 ticks.
                        :max-lifetime (/ (* 20 1000) internal-time-units-per-second)
                        args)))
      (setf (pool-clock pool)
            (lambda () (bt2:with-lock-held (clock-lock) (incf now))))
      (let* ((workers
               (loop repeat 8
                     collect (bt2:make-thread
                              (lambda ()
                                (let ((*random-state* (make-random-state t)))
                                  ;; Interrupts land only inside an iteration; one pending when
                                  ;; the loop ends is caught here instead of killing the thread.
                                  (handler-case
                                      (let ((*armed* t))
                                        (without-interrupts*
                                          (loop repeat 1000
                                                do (handler-case
                                                       (with-local-interrupts*
                                                         (with-connection (conn pool)
                                                           ;; Bookkeeping is not interrupted halfway,
                                                           ;; or a stale entry would look like a double lend.
                                                           (without-interrupts*
                                                             (bt2:with-lock-held (stat-lock)
                                                               (if (gethash conn lent)
                                                                   (incf double-lends)
                                                                   (setf (gethash conn lent) t))
                                                               (when (or (minusp (pool-active-count pool))
                                                                         (minusp (pool-idle-count pool)))
                                                                 (incf negative-counts)))
                                                             (unwind-protect
                                                                  (with-local-interrupts*
                                                                    (when (zerop (random 4))
                                                                      (bt2:thread-yield)))
                                                               (bt2:with-lock-held (stat-lock)
                                                                 (remhash conn lent))))))
                                                     ((or interrupted too-many-open-connection injected-failure) ()
                                                       nil)
                                                     (error (e)
                                                       (bt2:with-lock-held (stat-lock)
                                                         (push e unexpected-errors)))))))
                                    (interrupted () nil)))))))
             (chaos
               (bt2:make-thread
                (lambda ()
                  (loop until stop
                        do (let ((target (nth (random (length workers)) workers)))
                             (when (ignore-errors
                                    (bt2:interrupt-thread target
                                                          (lambda ()
                                                            (when *armed*
                                                              (error 'interrupted))))
                                    t)
                               (incf interrupts)))
                           (sleep 0.001)))))
             (finished (every (lambda (worker) (join-within worker 120)) workers)))
        (setf stop t)
        (ok finished "Every worker finished")
        (ok (join-within chaos 10) "The chaos thread stopped")
        (when finished
          (when (getf args :idle-timeout)
            (sleep 0.2))
          (ok (plusp interrupts) "Interrupts were actually sent")
          (ok (null unexpected-errors) (format nil "No unexpected errors: ~S" unexpected-errors))
          (ok (= double-lends 0) "No connection lent to two borrowers at once")
          (ok (= double-disconnects 0) "No connection disconnected twice")
          (ok (= negative-counts 0))
          (ok (= (pool-active-count pool) 0) "Every slot came back")
          (ok (= (pool-open-count pool) (pool-idle-count pool)))
          (ok (= (hash-table-count (pool-created-at-table pool)) (pool-open-count pool)))
          ;; Interrupted right after the connector returns or inside the disconnector, a physical
          ;; connection can be left open; each such leak takes one interrupt.
          (ok (<= (pool-open-count pool) live (+ (pool-open-count pool) interrupts))
              (format nil "live=~A open=~A interrupts=~A" live (pool-open-count pool) interrupts)))))))
