#!/usr/bin/bash
set -Eeuo pipefail

url=${KEA_CONTROL_AGENT_URL:-http://127.0.0.1:8000/}

request() {
  curl --fail --silent --show-error \
    --user kea:kea \
    --header 'Content-Type: application/json' \
    --data "{\"command\":\"$1\",\"service\":[\"dhcp4\"]}" \
    "$url"
}

check_command() {
  local command=$1
  local response

  for attempt in {1..30}; do
    if response=$(request "$command" 2>/dev/null); then
      break
    fi
    sleep 1
  done

  if [[ -z "${response:-}" ]] || ! grep -Eq '"result"[[:space:]]*:[[:space:]]*0' <<<"$response"; then
    printf 'FAIL %s: %s\n' "$command" "${response:-Control Agent did not become ready}" >&2
    exit 1
  fi

  printf 'PASS %s\n' "$command"
}

check_command reservation-get-all
check_command lease4-get-all
