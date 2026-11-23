# Smart Proxy extension integration tests

This shared repository contains integration-test suites and container images
for Foreman Smart Proxy and its extensions. The runner uses the target
checkout's Ruby bundle, so it can test a local branch or a pull request without
assuming where either repository is located. These tests are for development
and CI only; do not use the images in production.

## Running integration tests

The Kea suite currently targets the Smart Proxy core repository. It runs the
test suite against the checked-out project code and a temporary Kea container.
You need Ruby and Bundler for the target project's supported Ruby version, its
test dependencies installed, and a container runtime. The runner defaults to
rootless Podman; set `CONTAINER_ENGINE=docker` to use Docker.
There is no separate Gemfile in this repository: `bundle exec` uses the target
checkout's dependencies.

From any directory inside the target checkout, run:

```sh
/path/to/smart-proxy-ext-test/bin/test-integration
```

The runner discovers the target checkout by looking for its `Gemfile` and
`Rakefile` in the current directory or a parent directory. Set `PROJECT_ROOT`
when running it from elsewhere:

```sh
PROJECT_ROOT=/path/to/smart-proxy \
  /path/to/smart-proxy-ext-test/bin/test-integration
```

The command is also suitable for CI. Check out the pull request under test and
this repository at a pinned tag or commit, install the pull request checkout's
bundle, then invoke the runner with `PROJECT_ROOT` set to that checkout. For
example, in the Smart Proxy pull request workflow:

```yaml
- uses: actions/checkout@v4
- uses: actions/checkout@v4
  with:
    repository: lzap/smart-proxy-ext-test
    ref: <pinned-tag-or-commit>
    path: smart-proxy-ext-test
- name: Run integration tests
  env:
    PROJECT_ROOT: ${{ github.workspace }}
    CONTAINER_ENGINE: docker
  run: ${{ github.workspace }}/smart-proxy-ext-test/bin/test-integration
```

On a `pull_request` workflow, the first checkout contains the PR merge ref by
default. Pinning the shared test repository keeps the suite version stable for
each CI run. The Smart Proxy workflow accepts the repository variable
`SMART_PROXY_EXT_TEST_REF` for that pin; while it is unset, it checks out the
shared repository's `main` branch.

The runner supports the following settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `PROJECT_ROOT` | Detected from the current directory | Checkout whose code and Ruby bundle the suite should use |
| `CONTAINER_ENGINE` | `podman` | Container CLI, such as `podman` or `docker` |
| `KEA_INTEGRATION_IMAGE` | `ghcr.io/lzap/smart-proxy-ext-test-kea:latest` | Kea image to run |
| `KEA_STARTUP_TIMEOUT` | `60` | Seconds to wait for the Kea Control Agent |

## Image for Kea

The `kea` image is built from CentOS Stream 10 and runs its Kea DHCPv4 package,
Control Agent, and PostgreSQL in one container. It uses the CentOS Kea 3.0
package and hooks, including the host commands and lease commands libraries.

The DHCPv4 subnet is `192.168.122.0/24`, with a dynamic pool from
`192.168.122.100` through `192.168.122.200`. Kea stores leases in memfile and
host reservations in a local PostgreSQL database. The `host_cmds`,
`lease_cmds`, and PostgreSQL hooks are enabled.

The Control Agent listens on TCP port `18123` and uses HTTP Basic authentication
with username `kea` and password `kea`. PostgreSQL is available only inside the
container and uses the same test credentials.

Build and run the image with rootless Podman:

```sh
podman build -t smart-proxy-ext-test-kea -f Containerfile.kea .
podman run --rm --name kea-test --publish 18123:18123/tcp \
  smart-proxy-ext-test-kea
```

The Control Agent is available at `http://127.0.0.1:18123/`. The DHCPv4 daemon
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
