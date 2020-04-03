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

- make-pool
- pool-max-open-count
- pool-max-idle-count
- pool-idle-timeout
- pool-open-count
- pool-active-count
- pool-idle-count
- fetch
- putback

## Author

* Eitaro Fukamachi (e.arrows@gmail.com)

## Copyright

Copyright (c) 2020 Eitaro Fukamachi (e.arrows@gmail.com)

## License

Licensed under the BSD 2-Clause License.
