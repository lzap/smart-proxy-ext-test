# Smart Proxy extension test images

Container images in this repository provide isolated test services for Foreman
Smart Proxy extensions. They are for development and integration tests only;
do not use them in production.

## Kea

The `kea` image is built from CentOS Stream 10 and runs its Kea DHCPv4 package,
Control Agent, and PostgreSQL in one container. It uses the CentOS Kea 3.0
package and hooks, including the host commands and lease commands libraries.

The DHCPv4 subnet is `192.168.122.0/24`, with a dynamic pool from
`192.168.122.100` through `192.168.122.200`. Kea stores leases in memfile and
host reservations in a local PostgreSQL database. The `host_cmds`,
`lease_cmds`, and PostgreSQL hooks are enabled.

The Control Agent listens on TCP port `8000` and uses HTTP Basic authentication
with username `kea` and password `kea`. PostgreSQL is available only inside the
container and uses the same test credentials.

Build and run the image with rootless Podman:

```sh
podman build -t smart-proxy-ext-test-kea -f Containerfile.kea .
podman run --rm --name kea-test --publish 8000:8000/tcp \
  smart-proxy-ext-test-kea
```

The Control Agent is available at `http://127.0.0.1:8000/`. The DHCPv4 daemon
listens only on the container's loopback interface, and its UDP port is not
published. It is present to provide the Control Agent API and hook commands.

`test.kea.sh` is a quick smoke test for the exposed Control Agent API. It checks
reservation and lease commands, then creates, reads, and deletes a randomly
identified host reservation:

```sh
./test.kea.sh
```

Images are published to GHCR on every push. Each service is discovered from a
root-level `Containerfile.<service>` and published as
`ghcr.io/lzap/smart-proxy-ext-test-<service>` with branch, commit, and default
branch `latest` tags.
