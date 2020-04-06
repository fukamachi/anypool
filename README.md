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
```

## API

### make-pool (&key name connector disconnector ping max-open-count max-idle-count timeout idle-timeout)

- `:name`: The name of a new pool. This is used to print the object.
- `:connector` (Required): A function to make and return a new connection object. It takes no arguments.
- `:disconnector`: A function to disconnect a given object. It takes a single argument which is made by `:connector`.
- `:ping`: A function to check if the given object is still available. It takes a single argument.
- `:max-open-count`: The maximum number of concurrently open connections. The default is `4` and can be configured with `*default-max-open-count*`.
- `:max-idle-count`: The maximum number of idle/pooled connections. The default is `2` and can be configured with `*default-max-idle-count*`.
- `:timeout`: The milliseconds to wait in `fetch` when the number of open connection reached to the maximum. If `nil`, it waits forever. The default is `nil`.
- `:idle-timeout`: The milliseconds to disconnect idle resources after they're `putback`ed to the pool. If `nil`, it won't disconnect automatically. The default is `nil`.

### pool-max-open-count (pool)

Return the maximum number of concurrently open connections. If the number of open connections reached to the limit, `fetch` waits until a connection is available.

### (setf pool-max-open-count) (new-max-open-count pool)

Set the maximum number of concurrently open connections.

### pool-max-idle-count (pool)

Return the maximum number of idle/pooled connections. If the number of idle connections reached to the limit, extra connections will be disconnected in `putback`.

### (setf pool-max-idle-count) (new-max-idle-count pool)

Set the maximum number of idle/pooled connections.

### pool-idle-timeout (pool)

Return the milliseconds to disconnect idle resources after they're `putback`ed to the pool. If `nil`, this feature is disabled.

### (setf pool-idle-timeout) (new-idle-timeout pool)

Set the milliseconds to disconnect idle resources after they're `putback`ed to the pool. If `nil`, this feature is disabled.

### pool-open-count (pool)

Return the number of currently open connections. The count is the sum of `pool-active-count` and `pool-idle-count`.

### pool-active-count (pool)

Return the number of currently in use connections.

### pool-idle-count (pool)

Return the number of currently idle connections.

### fetch (pool)

Return an available resource from the `pool`. If no open resources available, it makes a new one with a function specified to `make-pool` as `:connector`.

No open resource available and can't open due to the `max-open-count`, this function waits for `:timeout` milliseconds. If `:timeout` specified to `nil`, this waits forever until a new one turns to available.

### putback (pool)

Send an in-use connection back to `pool` to make it reusable by other threads. If the number of idle connections is reached to `pool-max-idle-count`, the connection will be disconnected immediately.

## Author

* Eitaro Fukamachi (e.arrows@gmail.com)

## Copyright

Copyright (c) 2020 Eitaro Fukamachi (e.arrows@gmail.com)

## License

Licensed under the BSD 2-Clause License.
