all: build test

LISP = "sbcl"

.PHONY: build
build:
	docker build -t anypool-test-image --build-arg LISP=${LISP} -f tests/Dockerfile .

.PHONY: test
test:
	docker run --rm -i -v ${PWD}:/app anypool-test-image
