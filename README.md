# Smart Proxy extension test images

Container images in this repository provide isolated test services for Foreman
Smart Proxy extensions. They are for development and integration tests only;
do not use them in production.

## Kea

The `kea` image is built from CentOS Stream 9 and runs Kea DHCPv4, the Kea
Control Agent, and PostgreSQL in one container. It uses ISC Kea 3.0 LTS so the
open source host commands hook and the Control Agent are both available.

The DHCPv4 subnet is `192.168.122.0/24`, with a dynamic pool from
`192.168.122.100` through `192.168.122.200`. Kea stores leases in memfile and
host reservations in a local PostgreSQL database. The `host_cmds`,
`lease_cmds`, and PostgreSQL hooks are enabled.

The Control Agent listens on TCP port `8000` and uses HTTP Basic authentication
with username `kea` and password `kea`. PostgreSQL is available only inside the
container and uses the same test credentials.

Build and run the image on a test network:

```sh
podman build -t smart-proxy-ext-test-kea -f Containerfile.kea .
podman run --rm --name kea-test --network host \
  --cap-add NET_RAW --cap-add NET_BIND_SERVICE \
  smart-proxy-ext-test-kea
```

With host networking, the Control Agent is available at
`http://127.0.0.1:8000/`. For a DHCP exchange, attach the container and test
client to an isolated network configured for `192.168.122.0/24`. Avoid exposing
this DHCP server to a network that has another active DHCP server.

`test.kea.sh` is a quick smoke test for the exposed Control Agent API. It checks
that reservation and lease commands return successfully:

```sh
./test.kea.sh
```

Images are published to GHCR on every push. Each service is discovered from a
root-level `Containerfile.<service>` and published as
`ghcr.io/lzap/smart-proxy-ext-test-<service>` with branch, commit, and default
branch `latest` tags.
