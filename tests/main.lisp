(defpackage #:anypool/tests
  (:use #:cl
        #:rove
        #:anypool))
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
                          :max-idle-count 1))
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
      (ok (signals (fetch pool)))
      (ok (= (pool-open-count pool) 2))
      (ok (= (pool-active-count pool) 2))
      (ok (= (pool-idle-count pool) 0)))

    (testing "'putback' can return a fetched object back"
      (ok (= (putback (pop active-objects) pool) 1))
      (ok (= (pool-open-count pool) 2))
      (ok (= (pool-active-count pool) 1))
      (ok (= (pool-idle-count pool) 1)))

    (testing "'putback' disallocates an idle object exceeding max-idle-count"
      (ok (outputs (putback (pop active-objects) pool)
                   "disallocated dummy1"))
      (ok (= (pool-open-count pool) 1))
      (ok (= (pool-active-count pool) 0))
      (ok (= (pool-idle-count pool) 1)))))

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

(deftest idle-timeout
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
      (ng (eq (fetch pool) object))
      (ok (= (pool-idle-count pool) 0)))))
