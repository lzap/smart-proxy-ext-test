#!/usr/bin/bash
set -Eeuo pipefail

PGDATA=${PGDATA:-/var/lib/pgsql/data}
export PGDATA

install -d -o postgres -g postgres /run/postgresql

initialized=false
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  install -d -o postgres -g postgres "$PGDATA"
  runuser -u postgres -- /usr/bin/initdb \
    --pgdata="$PGDATA" \
    --auth-local=peer \
    --auth-host=scram-sha-256
  initialized=true
fi

runuser -u postgres -- /usr/bin/pg_ctl -D "$PGDATA" -l /dev/stderr -w start \
  -o "-c listen_addresses=127.0.0.1 -c logging_collector=off"

shutdown() {
  status=$?
  trap - EXIT INT TERM

  if [[ -n "${dhcp4_pid:-}" ]]; then
    kill "$dhcp4_pid" 2>/dev/null || true
    wait "$dhcp4_pid" 2>/dev/null || true
  fi
  if [[ -n "${ctrl_agent_pid:-}" ]]; then
    kill "$ctrl_agent_pid" 2>/dev/null || true
    wait "$ctrl_agent_pid" 2>/dev/null || true
  fi

  runuser -u postgres -- /usr/bin/pg_ctl -D "$PGDATA" -m fast -w stop \
    >/dev/null 2>&1 || true
  exit "$status"
}
trap shutdown EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for attempt in {1..30}; do
  if pg_isready --host 127.0.0.1 --quiet; then
    break
  fi
  sleep 1
done
pg_isready --host 127.0.0.1

runuser -u postgres -- psql --dbname postgres --set ON_ERROR_STOP=1 <<'SQL'
DO $create_role$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kea') THEN
    CREATE ROLE kea LOGIN PASSWORD 'kea';
  ELSE
    ALTER ROLE kea WITH LOGIN PASSWORD 'kea';
  END IF;
END
$create_role$;
SQL

if ! runuser -u postgres -- psql --dbname postgres \
    --tuples-only --no-align --command \
    "SELECT 1 FROM pg_database WHERE datname = 'kea'" | grep -q 1; then
  runuser -u postgres -- createdb --owner kea kea
fi

if [[ "$initialized" == true ]] || \
   ! kea-admin db-version pgsql -u kea -p kea -n kea -h 127.0.0.1 >/dev/null 2>&1; then
  kea-admin db-init pgsql -u kea -p kea -n kea -h 127.0.0.1
fi

install -d -o kea -g kea /var/run/kea
chmod 0750 /var/run/kea
/usr/sbin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf -p 1067 &
dhcp4_pid=$!
/usr/sbin/kea-ctrl-agent -c /etc/kea/kea-ctrl-agent.conf &
ctrl_agent_pid=$!

wait -n "$dhcp4_pid" "$ctrl_agent_pid"
