(defpackage #:anypool
  (:nicknames #:anypool/main)
  (:use #:cl)
  (:import-from #:bordeaux-threads)
  (:import-from #:cl-speedy-queue
                #:make-queue
                #:enqueue
                #:dequeue
                #:queue-count
                #:queue-full-p
                #:queue-peek)
  (:export #:*default-max-open-count*
           #:*default-max-idle-count*
           #:pool
           #:make-pool
           #:pool-name
           #:pool-max-open-count
           #:pool-max-idle-count
           #:pool-idle-timeout
           #:pool-max-lifetime
           #:pool-active-count
           #:pool-idle-count
           #:pool-open-count
           #:pool-overflow-count
           #:fetch
           #:putback
           #:too-many-open-connection
           #:error-max-open-limit
           #:with-connection))

(in-package #:anypool)

(defvar *default-max-open-count* 4)
(defvar *default-max-idle-count* 2)

;;; SB-EXT:WITH-TIMEOUT and INTERRUPT-THREAD can unwind a thread between any two forms. Slot
;;; accounting runs with them deferred so a slot is never lost or freed twice. Only SBCL is
;;; protected; elsewhere these are PROGN.

(defmacro without-interrupts* (&body body)
  #+sbcl `(sb-sys:without-interrupts ,@body)
  #-sbcl `(progn ,@body))

(defmacro with-local-interrupts* (&body body)
  "Allow interrupts in BODY again. Must appear lexically inside WITHOUT-INTERRUPTS*."
  #+sbcl `(sb-sys:with-local-interrupts ,@body)
  #-sbcl `(progn ,@body))

(defmacro allow-with-interrupts* (&body body)
  "Keep interrupts deferred in BODY, but let a WITH-LOCAL-INTERRUPTS* further in allow them.
Must appear lexically inside WITHOUT-INTERRUPTS*."
  #+sbcl `(sb-sys:allow-with-interrupts ,@body)
  #-sbcl `(progn ,@body))

(defun make-queue* (size)
  (if (zerop size)
      (make-array 2 :initial-contents '(2 2))
      (make-queue size)))

(defun queue-peek* (queue)
  (if (= (length queue) 2)
      (values nil nil)
      (queue-peek queue)))

(defstruct (pool (:constructor nil))  ; Don't generate constructor for base struct
  name
  connector
  disconnector
  ping
  max-open-count
  max-idle-count
  unlimited-p
  idle-timeout
  timeout
  ;; Read-only because enabling it on a live pool would leave connections without a creation time.
  (max-lifetime nil :read-only t)
  ;; Internal
  storage ; queue object
  (active-count 0 :type fixnum)
  (lock (bt2:make-lock :name "ANYPOOL-LOCK"))
  (wait-lock (bt2:make-lock :name "ANYPOOL-OPENWAIT-LOCK"))
  (wait-condvar (bt2:make-condition-variable :name "ANYPOOL-OPENWAIT"))
  (lifetime-limit nil :read-only t) ; max-lifetime * internal-time-units-per-second, exact
  ;; Connection -> creation time. Kept apart from ITEM, which lives for one idle period only.
  (created-at-table nil :read-only t)
  (clock #'get-internal-real-time))

(defstruct (pool-without-timeout
            (:include pool)
            (:conc-name pool-)
            (:constructor %make-pool-without-timeout)))

(defstruct (pool-with-timeout
            (:include pool)
            (:conc-name pool-)
            (:constructor %make-pool-with-timeout))
  (timeout-in-queue-count 0 :type fixnum))

(defstruct (item (:constructor make-item (object)))
  object
  idle-timer
  (active-p nil)
  (timeout-p nil))

(defmethod print-object ((object pool) stream)
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "~@[~S ~](OPEN=~A / IDLE=~A)"
            (pool-name object)
            (pool-open-count object)
            (pool-idle-count object))))

(defun pool-idle-count (pool)
  (etypecase pool
    (pool-without-timeout
     (queue-count (pool-storage pool)))
    (pool-with-timeout
     (- (queue-count (pool-storage pool))
        (pool-timeout-in-queue-count pool)))))

(defun pool-open-count (pool)
  (+ (pool-active-count pool)
     (pool-idle-count pool)))

(defun pool-overflow-count (pool)
  "Number of connections beyond max-open-count (0 if unlimited)."
  (if (pool-unlimited-p pool)
      0
      (max 0 (- (pool-active-count pool)
                (pool-max-open-count pool)))))

(define-condition anypool-error (error) ())
(define-condition too-many-open-connection (anypool-error)
  ((limit :initarg :limit
          :reader error-max-open-limit))
  (:report (lambda (condition stream)
             (format stream "Too many open connection and couldn't open a new one (limit: ~A)"
                     (slot-value condition 'limit)))))

(define-condition resource-already-in-pool (anypool-error)
  ((resource :initarg :resource))
  (:report (lambda (condition stream)
             (format stream "The connector returned ~S, which the pool already manages. ~
                             With max-lifetime, it must return a new object on every call."
                     (slot-value condition 'resource)))))

(defun lifetime-limit (max-lifetime)
  "Return MAX-LIFETIME milliseconds times internal-time-units-per-second as an exact rational.
Comparing it with 1000 times the elapsed internal time decides expiry without rounding."
  (or (and (typep max-lifetime '(real (0)))
           ;; RATIONAL signals on a float infinity.
           (ignore-errors (* (rational max-lifetime) internal-time-units-per-second)))
      (error 'type-error :datum max-lifetime :expected-type '(or null (real (0))))))

(defun make-pool (&key name
                       connector
                       disconnector
                       (ping (constantly t))
                       (max-open-count *default-max-open-count*)
                       (max-idle-count *default-max-idle-count*)
                       timeout
                       idle-timeout
                       max-lifetime)
  "Create a connection pool. Returns pool-without-timeout or pool-with-timeout based on idle-timeout."
  (let* ((unlimited-p (null max-open-count))
         (max-open-count (or max-open-count most-positive-fixnum))
         (storage (make-queue* (min max-open-count max-idle-count)))
         (lifetime-limit (and max-lifetime (lifetime-limit max-lifetime)))
         (created-at-table (and max-lifetime (make-hash-table :test 'eql))))
    (if idle-timeout
        (%make-pool-with-timeout
         :name name
         :connector connector
         :disconnector disconnector
         :ping ping
         :max-open-count max-open-count
         :max-idle-count max-idle-count
         :unlimited-p unlimited-p
         :idle-timeout idle-timeout
         :timeout timeout
         :max-lifetime max-lifetime
         :lifetime-limit lifetime-limit
         :created-at-table created-at-table
         :storage storage)
        (%make-pool-without-timeout
         :name name
         :connector connector
         :disconnector disconnector
         :ping ping
         :max-open-count max-open-count
         :max-idle-count max-idle-count
         :unlimited-p unlimited-p
         :idle-timeout nil
         :timeout timeout
         :max-lifetime max-lifetime
         :lifetime-limit lifetime-limit
         :created-at-table created-at-table
         :storage storage))))

(defun forget-created-at (pool conn)
  (let ((table (pool-created-at-table pool)))
    (when table
      (remhash conn table))))

(defun register-created-at (pool conn)
  "Record now as the creation time of CONN, which the connector has just returned."
  (let ((table (pool-created-at-table pool)))
    ;; Overwriting would silently restart the lifetime of a connection that may be lent out.
    (when (nth-value 1 (gethash conn table))
      (error 'resource-already-in-pool :resource conn))
    (setf (gethash conn table) (funcall (pool-clock pool)))))

(defun created-at (pool conn)
  "With the pool lock held, return the creation time recorded for CONN, or NIL."
  (let ((table (pool-created-at-table pool)))
    (and table (gethash conn table))))

(defun expired-at-p (pool created-at)
  "Whether a connection created at CREATED-AT has reached max-lifetime. The clock is not read when
max-lifetime is disabled. A NIL CREATED-AT, i.e. not from this pool's connector, counts as expired."
  (when (pool-max-lifetime pool)
    (or (null created-at)
        (>= (* 1000 (- (funcall (pool-clock pool)) created-at))
            (pool-lifetime-limit pool)))))

(defun expired-p (pool conn)
  "With the pool lock held, whether CONN has reached max-lifetime."
  (and (pool-max-lifetime pool)
       (expired-at-p pool (created-at pool conn))))

(defun lendable-p (pool conn created-at)
  "Without the pool lock, check an idle CONN that fetch has taken out. Retiring a rejected CONN is up
to the caller. Lifetime is checked again after PING, which may take long enough for CONN to expire."
  (let ((ping (pool-ping pool)))
    (and (not (expired-at-p pool created-at))
         (or (null ping) (funcall ping conn))
         (not (expired-at-p pool created-at)))))

(defun disconnect-quietly (pool conn)
  "Disconnect CONN, which the pool will not lend again, ignoring any ERROR from the disconnector.
An error an interrupt signals there is ignored too; SB-EXT:TIMEOUT and non-local exits still take effect."
  (let ((disconnector (pool-disconnector pool)))
    (when disconnector
      (ignore-errors (funcall disconnector conn)))))

#+sbcl
(defun make-idle-timer (item timeout-fn)
  (sb-ext:make-timer
    (lambda ()
      (unless (item-timeout-p item)
        (funcall timeout-fn (item-object item))))
    :thread t))

(defun take-idle (pool)
  "With the pool lock held, dequeue an idle connection and return it with its creation time and
queue item, or NIL when none is left. A dequeued item is marked active so its idle timer leaves it alone."
  (etypecase pool
    (pool-without-timeout
     (let ((storage (pool-storage pool)))
       (unless (zerop (queue-count storage))
         (let ((conn (dequeue storage)))
           (values conn (created-at pool conn) nil)))))
    (pool-with-timeout
     (loop
       ;; Fail-safe for cases where pool-idle-count is negative
       (when (<= (pool-idle-count pool) 0)
         (return nil))
       (let ((item (dequeue (pool-storage pool))))
         (if (item-timeout-p item)
             (decf (pool-timeout-in-queue-count pool))
             (let ((conn (item-object item)))
               (setf (item-active-p item) t)
               (return (values conn (created-at pool conn) item)))))))))

(defun can-open-p (pool)
  (or (pool-unlimited-p pool)
      (< (pool-open-count pool) (pool-max-open-count pool))))

(defun wait-for-slot (pool)
  "With the pool lock held, wait until a slot may have been freed; the lock is held again on return.
Return NIL when TIMEOUT runs out, so the caller can signal after releasing the lock."
  (with-slots (lock timeout wait-lock wait-condvar) pool
    (unless (and (numberp timeout)
                 (zerop timeout))
      ;; SBCL's mutex release and grab are not interrupt-safe: interrupted halfway, LOCK is left
      ;; taken by no thread and every later fetch hangs. Interrupts are allowed only while sleeping.
      (without-interrupts*
        (unwind-protect
             #+ccl
             (progn
               (bt2:release-lock lock)
               (if timeout
                   (ccl:timed-wait-on-semaphore wait-condvar (/ timeout 1000d0))
                   (ccl:wait-on-semaphore wait-condvar)))
             #-ccl
             ;; WAIT-LOCK is taken before LOCK is released: putback notifies under
             ;; WAIT-LOCK, so its wakeup cannot fall between our check and the wait.
             (bt2:with-lock-held (wait-lock)
               (bt2:release-lock lock)
               (allow-with-interrupts*
                 (bt2:condition-wait wait-condvar wait-lock
                                     :timeout (and timeout (/ timeout 1000d0)))))
          (allow-with-interrupts* (bt2:acquire-lock lock)))))))

(defun release-idle-timer (item)
  "Stop the idle timer of ITEM, which fetch has taken out. Called without the pool lock, which the
timer callback takes."
  #+sbcl
  (when (and item (item-idle-timer item))
    (sb-ext:unschedule-timer (item-idle-timer item)))
  #-sbcl
  (declare (ignore item)))

(defun fetch (pool)
  "Fetch a connection from the pool.
PING and CONNECTOR run without the pool lock, so a slow or stuck one delays only this call. The slot
they work in is counted as active meanwhile, so the pool never opens more than max-open-count."
  (let ((lock (pool-lock pool))
        (held nil)                      ; this call owns a slot counted in ACTIVE-COUNT
        (owned nil)                     ; a connection only this call holds
        (lent nil))
    (without-interrupts*
      (unwind-protect
           (progn
             (with-local-interrupts*
               (loop
                 (let ((action nil)
                       (created-at nil)
                       (item nil))
                   (bt2:with-lock-held (lock)
                     (loop
                       ;; Counts change together with HELD and OWNED; an interrupt in between
                       ;; would leak the slot or free it twice.
                       (without-interrupts*
                         (multiple-value-bind (conn conn-created-at conn-item) (take-idle pool)
                           (cond
                             (conn
                              (unless held
                                (incf (pool-active-count pool))
                                (setf held t))
                              (setf owned conn
                                    created-at conn-created-at
                                    item conn-item
                                    action :check))
                             ;; A slot kept after retiring a connection is used, never waited
                             ;; with, or every slot could end up held by a waiter.
                             ((or held (can-open-p pool))
                              (unless held
                                (incf (pool-active-count pool))
                                (setf held t))
                              (setf action :open)))))
                       (when action
                         (return))
                       (unless (wait-for-slot pool)
                         (return))))
                   ;; Signalled outside the lock: handlers may do I/O, and every fetch and putback
                   ;; would wait for them.
                   (unless action
                     (error 'too-many-open-connection
                            :limit (pool-max-open-count pool)))
                   (ecase action
                     (:check
                      (release-idle-timer item)
                      (when (lendable-p pool owned created-at)
                        (return))
                      ;; Ownership and the creation time are dropped together before disconnecting,
                      ;; so an interrupt there frees the slot without a second disconnect.
                      (let ((conn owned))
                        (bt2:with-lock-held (lock)
                          (without-interrupts*
                            (forget-created-at pool conn)
                            (setf owned nil)))
                        (disconnect-quietly pool conn)))
                     (:open
                      (let ((conn (funcall (pool-connector pool))))
                        (bt2:with-lock-held (lock)
                          ;; Not OWNED if the connector returned one the pool already manages, so
                          ;; the cleanup leaves that connection alone.
                          (without-interrupts*
                            (when (pool-max-lifetime pool)
                              (register-created-at pool conn))
                            (setf owned conn))))
                      (return))))))
             ;; The connection is safe from interrupts until FETCH returns; past that the caller
             ;; must defer them, as WITH-CONNECTION does.
             (setf lent owned
                   owned nil))
        (unless lent
          ;; The disconnector may exit non-locally; the slot is freed regardless. Interrupts are
          ;; allowed only in the disconnect, which can block and must stay cancellable.
          (unwind-protect
               (when owned
                 (let ((conn owned))
                   (bt2:with-lock-held (lock)
                     (setf owned nil)
                     (forget-created-at pool conn))
                   (with-local-interrupts* (disconnect-quietly pool conn))))
            (when held
              (release-slot pool))))))
    lent))

(defun notify-waiter (pool)
  (bt2:with-lock-held ((pool-wait-lock pool))
    (bt2:condition-notify (pool-wait-condvar pool))))

(defun release-slot (pool)
  "Free one slot counted in ACTIVE-COUNT and wake a waiter to claim it."
  (without-interrupts*
    (bt2:with-lock-held ((pool-lock pool))
      (decf (pool-active-count pool)))
    (notify-waiter pool)))

(defun call-then-release-slot (pool fn)
  "Call FN, then free the slot of a lent-out connection and wake a waiter even if FN fails.
The slot is held until FN returns so a waiter cannot open a replacement while the old one is still open."
  (unwind-protect (funcall fn)
    (release-slot pool)))

(defmacro define-putback-impl (name pool-type &key before-putback enqueue-logic)
  "Generate a putback implementation with type-specific logic."
  `(defun ,name (conn pool)
     (declare (type ,pool-type pool))
     ;; Interrupted between the decision and its outcome, CONN would be neither queued nor its
     ;; slot freed. Only the disconnect, which does I/O, can be interrupted.
     (without-interrupts*
       ,@(when before-putback (list before-putback))
       (with-slots (disconnector storage lock) pool
         (ecase (bt2:with-lock-held (lock)
                  (cond
                    ((expired-p pool conn)
                     (forget-created-at pool conn)
                     :expired)
                    ((queue-full-p storage)
                     (forget-created-at pool conn)
                     :full)
                    (t
                     ,enqueue-logic
                     (decf (pool-active-count pool))
                     :enqueued)))
           (:enqueued
            (notify-waiter pool))
           (:expired
            ;; Errors are ignored as for a failed ping; the connection is gone either way.
            (call-then-release-slot pool
                                    (lambda ()
                                      (with-local-interrupts*
                                        (disconnect-quietly pool conn)))))
           (:full
            (call-then-release-slot pool
                                    (lambda ()
                                      (with-local-interrupts*
                                        (when disconnector
                                          (funcall disconnector conn)))))))))
     (values)))

(defun dequeue-timeout-resources (pool)
  (declare (type pool-with-timeout pool))
  (with-slots (storage lock) pool
    (loop
      (bt2:with-lock-held (lock)
        (let ((item (queue-peek* storage)))
          (when (or (null item)
                    (not (item-timeout-p item)))
            (return))
          (decf (pool-timeout-in-queue-count pool))
          (dequeue storage))))))

(define-putback-impl %putback-without-timeout pool-without-timeout
  :enqueue-logic
  (enqueue conn storage))

(define-putback-impl %putback-with-timeout pool-with-timeout
  :before-putback
  (dequeue-timeout-resources pool)
  :enqueue-logic
  (let ((item (make-item conn)))
    #+sbcl
    (with-slots (idle-timeout) pool
      (setf (item-idle-timer item)
            (make-idle-timer item
                             (lambda (conn)
                               (let ((activep
                                       (bt2:with-lock-held (lock)
                                         (let ((activep (item-active-p item)))
                                           (unless activep
                                             (setf (item-timeout-p item) t)
                                             (incf (pool-timeout-in-queue-count pool))
                                             (forget-created-at pool conn))
                                           activep))))
                                 (unless activep
                                   (when disconnector
                                     (funcall disconnector conn)))))))
      (sb-ext:schedule-timer (item-idle-timer item)
                             (/ idle-timeout 1000d0)))
    (enqueue item storage)))

(defun putback (conn pool)
  "Return a connection to the pool."
  (etypecase pool
    (pool-without-timeout (%putback-without-timeout conn pool))
    (pool-with-timeout (%putback-with-timeout conn pool))))

(defmacro with-connection ((conn pool) &body body)
  (let ((g-pool (gensym "POOL")))
    ;; FETCH/PUTBACK go through ALLOW-WITH-INTERRUPTS*, not WITH-LOCAL-INTERRUPTS*: their own
    ;; WITHOUT-INTERRUPTS* would otherwise deliver a pending interrupt before CONN is bound.
    `(let ((,g-pool ,pool)
           (,conn nil))
       (without-interrupts*
         (unwind-protect
              (progn
                (setf ,conn (allow-with-interrupts* (fetch ,g-pool)))
                (with-local-interrupts* ,@body))
           (when ,conn
             (allow-with-interrupts* (putback ,conn ,g-pool))))))))
