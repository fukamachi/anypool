ARG LISP=sbcl
FROM fukamachi/$LISP

WORKDIR /app

RUN set -x; \
  ros -e '(ql-dist:install-dist "http://dist.ultralisp.org/" :prompt nil)' && \
  ros install fukamachi/rove && \
  mkdir -p "$HOME/.config/common-lisp/source-registry.conf.d/" && \
  echo '(:tree "/app")' >> "$HOME/.config/common-lisp/source-registry.conf.d/ci.conf"

ENTRYPOINT ["rove"]
CMD ["anypool.asd"]
