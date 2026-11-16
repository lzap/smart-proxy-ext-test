.DEFAULT_GOAL := start

IMAGE ?= ghcr.io/lzap/smart-proxy-ext-test-kea:latest
CONTAINER_NAME ?= smart-proxy-ext-test-kea

.PHONY: start stop test

start:
	podman pull $(IMAGE)
	@if podman container exists $(CONTAINER_NAME); then \
		podman rm --force $(CONTAINER_NAME); \
	fi
	podman run --detach --name $(CONTAINER_NAME) \
		--publish 127.0.0.1:18123:18123/tcp $(IMAGE)

stop:
	podman stop $(CONTAINER_NAME)

test:
	./test.kea.sh
