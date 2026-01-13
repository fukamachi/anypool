(defpackage #:anypool/tests
  (:use #:cl
        #:rove
        #:anypool)
  (:import-from #:anypool
                #:pool-storage
                #:dequeue-timeout-resources)
  (:import-from #:cl-speedy-queue
                #:queue-count)
  (:import-from #:anypool/tests/utils
                #:*mock-function*
                #:with-mock-functions))
(in-package #:anypool/tests)

(deftest make-pool
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () 'dummy))))
    (ok (typep pool 'pool))
    (ok (typep (pool-max-open-count pool) 'fixnum))
    (ok (typep (pool-max-idle-count pool) 'fixnum))
    (ok (= (pool-open-count pool) 0))
    (ok (= (pool-active-count pool) 0))
    (ok (= (pool-idle-count pool) 0))))

(deftest fetch-and-putback
  (let* ((connector (let ((count 0))
                      (lambda ()
                        (format nil "dummy~D" (incf count)))))
         (disconnector (lambda (object)
                         (format t "disallocated ~A" object)))
         (pool (make-pool :name "test pool"
                          :connector connector
                          :disconnector disconnector
                          :max-open-count 2
                          :max-idle-count 1
                          ;; Timeout immediately and raise an error
                          :timeout 0))
         active-objects)
    (testing "'fetch' can allocate a new object"
      (push (fetch pool) active-objects)
      (ok (string= (first active-objects) "dummy1"))
      (ok (= (pool-open-count pool) 1))
      (ok (= (pool-active-count pool) 1))
      (ok (= (pool-idle-count pool) 0))

      (push (fetch pool) active-objects)
      (ok (string= (first active-objects) "dummy2"))
      (ok (= (pool-open-count pool) 2))
      (ok (= (pool-active-count pool) 2))
      (ok (= (pool-idle-count pool) 0)))

    (testing "'fetch' can't allocate exceeding the max-open-count"
      (ok (signals (fetch pool) 'too-many-open-connection))
      (ok (= (pool-open-count pool) 2))
      (ok (= (pool-active-count pool) 2))
      (ok (= (pool-idle-count pool) 0)))

    (testing "'putback' can return a fetched object back"
      (putback (pop active-objects) pool)
      (ok (= (pool-active-count pool) 1))
      (ok (= (pool-open-count pool) 2))
      (ok (= (pool-active-count pool) 1))
      (ok (= (pool-idle-count pool) 1)))

    (testing "'putback' disallocates an idle object exceeding max-idle-count"
      (ok (outputs (putback (pop active-objects) pool)
                   "disallocated dummy1"))
      (ok (= (pool-open-count pool) 1))
      (ok (= (pool-active-count pool) 0))
      (ok (= (pool-idle-count pool) 1)))))

#|
(deftest wait-forever
  (let ((pool (make-pool :name "test pool"
                         :connector #'get-internal-real-time
                         :max-open-count 1
                         :timeout nil)))
    (fetch pool)
    (fetch pool)
    (fail "wait forever")))
|#

(deftest ping
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () (get-internal-real-time))
                         :ping (lambda (item)
                                 (< (get-internal-real-time)
                                    (+ item (/ internal-time-units-per-second 2)))))))
    (let ((object (fetch pool)))
      (putback object pool)
      (ok (eq (fetch pool) object))
      (putback object pool)
      (sleep 0.5)
      (ng (eq (fetch pool) object)))))

(deftest ping-failure-calls-disconnector
  (testing "pool without idle-timeout"
    (let ((pool (make-pool :name "test pool"
                           :connector (lambda () (get-internal-real-time))
                           :disconnector (lambda (conn)
                                           (declare (ignore conn))
                                           (format t "disconnected"))
                           :ping (lambda (item)
                                   (< (get-internal-real-time)
                                      (+ item (/ internal-time-units-per-second 2)))))))
      (let ((object (fetch pool)))
        (putback object pool)
        (sleep 0.5)
        ;; Ping will fail, disconnector should be called
        (ok (outputs (fetch pool) "disconnected")
            "Disconnector is called when ping fails"))))
  (testing "pool with idle-timeout"
    #+sbcl
    (let ((pool (make-pool :name "test pool"
                           :connector (lambda () (get-internal-real-time))
                           :disconnector (lambda (conn)
                                           (declare (ignore conn))
                                           (format t "disconnected"))
                           :ping (lambda (item)
                                   (< (get-internal-real-time)
                                      (+ item (/ internal-time-units-per-second 2))))
                           :idle-timeout 10000))) ; Long timeout so timer doesn't fire
      (let ((object (fetch pool)))
        (putback object pool)
        (sleep 0.5)
        ;; Ping will fail, disconnector should be called
        (ok (outputs (fetch pool) "disconnected")
            "Disconnector is called when ping fails (with idle-timeout)")))))

(deftest idle-timeout
  #-sbcl (skip ":idle-timeout works only on SBCL")
  #+sbcl
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () (get-internal-real-time))
                         :idle-timeout 100)))
    (let ((object (fetch pool)))
      (putback object pool)
      (ok (eq (fetch pool) object))
      (putback object pool)
      (ok (= (pool-idle-count pool) 1))
      (sleep 0.2)
      (ok (= (pool-idle-count pool) 0))
      (ok (= (queue-count (pool-storage pool)) 1))
      (dequeue-timeout-resources pool)
      (ok (= (pool-idle-count pool) 0))
      (ok (= (queue-count (pool-storage pool)) 0))
      (ng (eq (fetch pool) object))
      (ok (= (pool-idle-count pool) 0))))

  #+sbcl
  (let* ((pool (make-pool :name "test pool"
                          :connector (lambda () (get-internal-real-time))
                          :max-open-count 20
                          :max-idle-count 20
                          :idle-timeout 1))
         (threads (loop repeat 20
                        collect (bt2:make-thread
                                 (lambda ()
                                   (loop
                                     repeat 1000000
                                     do (let ((object (fetch pool)))
                                          (putback object pool))))))))
    (dolist (thread threads)
      (bt2:join-thread thread))
    (pass "passed")))

#+sbcl
(deftest race-condition-between-fetch-and-idle-timer-thread
  (let ((pool (make-pool :name "race-pool-mock"
                         :connector (lambda () (get-internal-real-time))
                         :max-open-count 2
                         :idle-timeout 100 ; Timeout after 0.1 seconds
                         )))

    ;; Preparation: Put one item in the pool
    (let ((item (fetch pool)))
      (putback item pool))

    (ok (= (pool-idle-count pool) 1) "Initial: 1 idle item")

    ;; Thread A: Execute fetch (mocked unschedule-timer will be called)
    (let ((thread-a (bt2:make-thread
                     (lambda ()
                       ;; Mock the SBCL system function unschedule-timer
                       (with-mock-functions ((sb-ext:unschedule-timer (timer)
                                               ;; 1. Sleep here to extend the lock release time
                                               (sleep 0.5)
                                               ;; 2. Call the original function (to preserve functionality)
                                               (funcall (gethash 'sb-ext:unschedule-timer *mock-function*) timer)))
                         (fetch pool))))))

      ;; Wait for the idle-timeout timer to fire (0.2 seconds wait > idle-timeout 0.1 seconds)
      (sleep 0.2)

      ;; Verification: Confirm that the timer interrupt doesn't cause idle-count to become negative
      (ok (zerop (pool-idle-count pool)) "Pool Idle Count should be 0")

      ;; Thread B: Confirm that QUEUE-UNDERFLOW-ERROR does not occur
      (ok (fetch pool))

      (bt2:join-thread thread-a))))

(deftest timeout
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () (get-internal-real-time))
                         :max-open-count 2
                         :timeout 200)))
    (let ((objects (list (fetch pool) (fetch pool))))
      (ok (= (pool-open-count pool) 2))
      (bt2:make-thread
        (lambda ()
          (sleep 0.1)
          (putback (pop objects) pool)))
      (ok (fetch pool))

      (bt2:make-thread
        (lambda ()
          (sleep 0.3)
          (putback (pop objects) pool)))
      (ok (signals (fetch pool) 'too-many-open-connection)))))

(deftest disable-pooling
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () (get-internal-real-time))
                         :max-open-count 4
                         :max-idle-count 0)))
    (let ((object (fetch pool)))
      (ok (= (pool-open-count pool) 1))
      (ok (= (pool-idle-count pool) 0))
      (putback object pool)
      (ok (= (pool-open-count pool) 0))
      (ok (= (pool-idle-count pool) 0)))))

(deftest unlimited-connections-basic
  (let* ((create-count 0)
         (pool (make-pool :name "test pool"
                          :connector (lambda () (incf create-count))
                          :max-open-count nil
                          :max-idle-count 10)))
    (testing "Fetch more than default limit should succeed"
      (let ((conns (loop repeat 100 collect (fetch pool))))
        (ok (= create-count 100) "Created 100 instances")
        (ok (= (pool-open-count pool) 100) "Pool reports 100 open connections")
        (ok (= (pool-active-count pool) 100) "All 100 connections are active")

        ;; Return all connections
        (mapc (lambda (c) (putback c pool)) conns)

        (ok (<= (pool-idle-count pool) 10) "Pool shrunk back to max-idle-count")
        (ok (= (pool-active-count pool) 0) "No active connections remain")))))

(deftest unlimited-never-blocks
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () (get-internal-real-time))
                         :max-open-count nil
                         :timeout 0)))
    (testing "Unlimited pool never blocks, even with timeout 0"
      (ok (loop repeat 100 always (fetch pool))
          "Fetch 100 times without blocking or erroring"))))

(deftest overflow-count-tracking
  (let* ((create-count 0)
         (pool (make-pool :name "test pool"
                          :connector (lambda () (incf create-count))
                          :max-open-count 5
                          :max-idle-count 3)))
    (testing "Overflow count is always 0 for limited pools"
      (ok (= (pool-overflow-count pool) 0) "Initially no overflow")

      (let ((conns (loop repeat 5 collect (fetch pool))))
        (ok (= (pool-overflow-count pool) 0) "No overflow at limit (5 active = 5 max)")
        (ok (= create-count 5) "Created 5 instances")

        ;; Return all connections
        (mapc (lambda (c) (putback c pool)) conns)

        (ok (= (pool-overflow-count pool) 0) "No overflow after putback")
        (ok (= (pool-active-count pool) 0) "No active connections")))))

(deftest overflow-count-unlimited
  (let ((pool (make-pool :name "test pool"
                         :connector (lambda () (get-internal-real-time))
                         :max-open-count nil)))
    (testing "Overflow count is always 0 for unlimited pools"
      (ok (= (pool-overflow-count pool) 0) "Initially 0")

      (loop repeat 100 do (fetch pool))

      (ok (= (pool-overflow-count pool) 0) "Still 0 after 100 fetches")
      (ok (= (pool-active-count pool) 100) "But 100 active connections"))))
