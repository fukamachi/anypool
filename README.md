# anypool

[![Build Status](https://github.com/fukamachi/anypool/workflows/CI/badge.svg)](https://github.com/fukamachi/anypool/actions?query=workflow%3ACI)

General-purpose connection pooling library.

## WARNING

This software is still ALPHA quality. The APIs will be likely to change.

## Usage

```common-lisp
(ql:quickload '(:anypool :dbi))
(use-package :anypool)

(defvar *connection-pool*
  (make-pool :name "dbi-connections"
             :connector (lambda ()
                          (dbi:connect :postgres
                                       :database-name "webapp"
                                       :username "fukamachi" :password "1ove1isp"))
             :disconnector #'dbi:disconnect
             :ping #'dbi:ping
             :max-open-count 10
             :max-idle-count 2))

(fetch *connection-pool*)
;=> #<DBD.POSTGRES:DBD-POSTGRES-CONNECTION {10054E07C3}>

(pool-open-count *connection-pool*)
;=> 1

(pool-idle-count *connection-pool*)
;=> 0

(putback *** *connection-pool*)
; No value

(pool-open-count *connection-pool*)
;=> 1

(pool-idle-count *connection-pool*)
;=> 1

;; Using `with-connection` macro.
(with-connection (mito:*connection* *connection-pool*)
  (mito:find-dao 'user :name "fukamachi"))

;; Unlimited connections mode (never blocks)
(defvar *object-pool*
  (make-pool :name "object-pool"
             :connector #'make-object
             :max-open-count nil      ; Unlimited!
             :max-idle-count 100))    ; But only keep 100 idle

;; This will never block, even under high load
(fetch *object-pool*)  ;=> Always succeeds

;; Stop reusing connections 5 minutes after they were opened
;; (5 minutes is only an example, not a recommended value).
(defvar *reader-pool*
  (make-pool :name "reader-connections"
             :connector (lambda ()
                          (dbi:connect :postgres
                                       :host "reader.example.com"
                                       :database-name "webapp"
                                       :username "fukamachi" :password "1ove1isp"))
             :disconnector #'dbi:disconnect
             :ping #'dbi:ping
             :max-lifetime (* 5 60 1000)))
```

## API

### [Constructor] make-pool (&key name connector disconnector ping max-open-count max-idle-count timeout idle-timeout max-lifetime)

- `:name`: The name of a new pool. This is used to print the object.
- `:connector` (Required): A function to make and return a new connection object. It takes no arguments. It must return a non-`nil` object. It runs without the pool lock and may be called from several threads at once, so it must be thread-safe.
- `:disconnector`: A function to disconnect a given object. It takes a single argument which is made by `:connector`.
- `:ping`: A function to check if the given object is still available. It takes a single argument. It runs without the pool lock and may be called from several threads at once, each on a different object. If it returns `nil`, the object is disconnected and `fetch` tries another one. If it signals an error, the object is disconnected, and then the error propagates from `fetch`. In both cases any error from `:disconnector` is ignored.
- `:max-open-count`: The maximum number of concurrently open connections. The default is `4` and can be configured with `*default-max-open-count*`. If `nil`, allows unlimited connections (never blocks or errors).
- `:max-idle-count`: The maximum number of idle/pooled connections. The default is `2` and can be configured with `*default-max-idle-count*`.
- `:timeout`: The milliseconds to wait in `fetch` when the number of open connection reached to the maximum. A slot in which another `fetch` is still connecting or pinging counts as open, so this also bounds how long `fetch` waits behind a slow connect. It bounds each wait, not the whole call: if another thread takes the slot that woke `fetch`, it waits again. If `nil`, it waits forever. The default is `nil`.
- `:idle-timeout`: The milliseconds to disconnect idle resources after they're `putback`ed to the pool. If `nil`, it won't disconnect automatically. The default is `nil`.
- `:max-lifetime`: The milliseconds after which a connection is no longer reused, counted from when `:connector` returned it. It must be a positive real number; `0`, negative numbers and non-numbers are rejected. If `nil`, connections are reused regardless of their age. The default is `nil`. See [max-lifetime](#max-lifetime).

The three time settings are independent:

- `:timeout` is how long `fetch` waits for a free slot when `max-open-count` is reached.
- `:idle-timeout` discards a connection that has stayed idle in the pool for that long. Each `putback` starts a new idle period.
- `:max-lifetime` stops reusing a connection once that long has passed since it was created, however often it has been used.

### [Accessor] pool-max-open-count (pool)

Return the maximum number of concurrently open connections. If the number of open connections reached to the limit, `fetch` waits until a connection is available.

### [Accessor] (setf pool-max-open-count) (new-max-open-count pool)

Set the maximum number of concurrently open connections.

### [Accessor] pool-max-idle-count (pool)

Return the maximum number of idle/pooled connections. If the number of idle connections reached to the limit, extra connections will be disconnected in `putback`.

### [Accessor] (setf pool-max-idle-count) (new-max-idle-count pool)

Set the maximum number of idle/pooled connections.

### [Accessor] pool-idle-timeout (pool)

Return the milliseconds to disconnect idle resources after they're `putback`ed to the pool. If `nil`, this feature is disabled.

### [Accessor] (setf pool-idle-timeout) (new-idle-timeout pool)

Set the milliseconds to disconnect idle resources after they're `putback`ed to the pool. If `nil`, this feature is disabled.

### [Accessor] pool-max-lifetime (pool)

Return the `:max-lifetime` given to `make-pool`, or `nil` if it is disabled. It is fixed when the pool is created and cannot be changed afterwards.

### [Accessor] pool-open-count (pool)

Return the number of currently open connections. The count is the sum of `pool-active-count` and `pool-idle-count`.

### [Accessor] pool-active-count (pool)

Return the number of currently in use connections.

### [Accessor] pool-idle-count (pool)

Return the number of currently idle connections.

### [Accessor] pool-overflow-count (pool)

Return the number of currently active connections beyond `pool-max-open-count`. Always returns `0` for pools created with `:max-open-count nil` (unlimited) or for limited pools (which never exceed their limit).

### [Function] fetch (pool)

Return an available resource from the `pool`. If no open resources available, it makes a new one with a function specified to `make-pool` as `:connector`.

No open resource available and can't open due to the `max-open-count`, this function waits for `:timeout` milliseconds. If `:timeout` specified to `nil`, this waits forever until a new one turns to available.

### [Function] putback (object pool)

Send an in-use connection back to `pool` to make it reusable by other threads. If the number of idle connections is reached to `pool-max-idle-count`, the connection will be disconnected immediately.

## Interrupts

On SBCL, `fetch`, `putback` and `with-connection` keep their slot accounting correct when the thread is interrupted, for example by `sb-ext:with-timeout` or `interrupt-thread`. The connector, the ping, the disconnector and the body of `with-connection` can still be interrupted.

- Use `with-connection` where you can. It defers interrupts from the moment `fetch` returns until the connection is bound, and while it is put back. If you call `fetch` and `putback` directly, an interrupt between `fetch` returning and your code taking the connection loses the connection and its slot.
- If `conn` in `with-connection` names a special variable, it is bound to `nil` while `fetch` runs.
- An interrupt right after `:connector` returns, before the pool records the connection, frees the slot but leaves that physical connection open. An interrupt while a retired connection is being disconnected can leave the connection open as well. The pool's counts stay correct in both cases.
- Where the pool ignores errors from `:disconnector` (after a failed ping, for an expired connection), it ignores every `error` signalled during the disconnect, including one that an interrupt function signals there. Conditions that are not errors, such as `sb-ext:timeout` from `sb-ext:with-timeout`, and non-local exits such as `throw` still take effect.
- On other implementations there is no protection against interrupts.

## max-lifetime

`:max-lifetime` lets a pool replace healthy connections on a schedule. It is meant for endpoints that pick a server when a connection is opened, such as a database reader endpoint: while old connections keep working, they never go back through that choice, so servers added later get no share of them. Once a connection reaches its lifetime, the pool stops lending it, and the next `fetch` that needs a connection calls `:connector` again.

What it guarantees:

- `fetch` never lends out a connection once `max-lifetime` has passed since `:connector` returned it. An idle connection is checked when `fetch` commits to lending it, which is after `:ping` returns. A new connection is lent at age zero: `fetch` hands it out right after recording its creation time, and no callback runs in between.
- Using a connection does not extend its lifetime. The creation time is kept across `fetch` and `putback`.
- A connection that expires while borrowed is not touched. It is disconnected when it is `putback`, and a thread waiting in `fetch` is woken to open a new one.
- It works with `:ping nil` and with a `:ping` that always succeeds. An expired connection is dropped without calling `:ping`.
- If `:disconnector` signals an error for an expired connection, the error is ignored, as for a connection whose ping failed. The connection is not reused either way.

What it does not do:

- It never disconnects a borrowed connection. A connection kept borrowed for a long time is used past its lifetime until it is `putback`.
- There is no timer for it. Expired connections are found in `fetch` and `putback`, so a pool that is not being used keeps them until it is used again (`:idle-timeout` still disconnects idle ones on its own schedule).
- It does not touch DNS or any cache. `:connector` has to open a new physical connection each time; if it hands out connections from another cache of its own, the old ones may come back.
- `:connector` must return a new object on each call while `:max-lifetime` is set. `fetch` signals an error if it returns an object the pool already manages, and leaves that object alone.
- Without `:disconnector`, an expired connection is only dropped from the pool; nothing releases its external resources explicitly.
- It gives new servers a chance to receive connections, but it does not balance load evenly among them.
- It does not make database changes safe by itself. If a server is stopped first, work on connections to it can fail.
- Connections opened at about the same time expire at about the same time, and are replaced together.

## Author

* Eitaro Fukamachi (e.arrows@gmail.com)

## Copyright

Copyright (c) 2020 Eitaro Fukamachi (e.arrows@gmail.com)

## License

Licensed under the BSD 2-Clause License.
