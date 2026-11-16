#!/usr/bin/bash
set -Eeuo pipefail

url=${KEA_CONTROL_AGENT_URL:-http://127.0.0.1:8000/}

request() {
  local command=$1
  local arguments=$2

  curl --fail --silent --show-error \
    --user kea:kea \
    --header 'Content-Type: application/json' \
    --data "{\"command\":\"$command\",\"arguments\":$arguments,\"service\":[\"dhcp4\"]}" \
    "$url"
}

check_command() {
  local command=$1
  local arguments=$2
  local response

  for attempt in {1..90}; do
    if response=$(request "$command" "$arguments" 2>/dev/null); then
      break
    fi
    sleep 1
  done

  if [[ -z "${response:-}" ]] || ! grep -Eq '"result"[[:space:]]*:[[:space:]]*(0|3)' <<<"$response"; then
    printf 'FAIL %s: %s\n' "$command" "${response:-Control Agent did not become ready}" >&2
    exit 1
  fi

  printf 'PASS %s\n' "$command"
}

check_success() {
  local command=$1
  local arguments=$2
  local response

  if ! response=$(request "$command" "$arguments") || \
     ! grep -Eq '"result"[[:space:]]*:[[:space:]]*0([,}]|$)' <<<"$response"; then
    printf 'FAIL %s: %s\n' "$command" "${response:-request failed}" >&2
    return 1
  fi

  printf 'PASS %s\n' "$command"
}

check_command reservation-get-all '{"subnet-id":1}'
check_command lease4-get-all '{"subnets":[1]}'

random_hex=$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')
hw_address="02:${random_hex:0:2}:${random_hex:2:2}:${random_hex:4:2}:${random_hex:6:2}:${random_hex:8:2}"
hostname="smoke-${random_hex}"

# Keep the reservation outside the dynamic pool (.100-.200).
random_slot=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
random_slot=$((random_slot % 152))
if (( random_slot < 98 )); then
  last_octet=$((random_slot + 2))
else
  last_octet=$((random_slot - 98 + 201))
fi
ip_address="192.168.122.${last_octet}"

reservation_added=false
delete_arguments="{\"subnet-id\":1,\"identifier-type\":\"hw-address\",\"identifier\":\"$hw_address\"}"
cleanup_reservation() {
  local status=$?
  local response
  trap - EXIT

  if [[ "$reservation_added" == true ]]; then
    if response=$(request reservation-del "$delete_arguments") && \
       grep -Eq '"result"[[:space:]]*:[[:space:]]*(0|3)([,}]|$)' <<<"$response"; then
      printf 'PASS reservation-del (cleanup)\n'
    else
      printf 'FAIL reservation-del (cleanup): %s\n' "${response:-request failed}" >&2
      status=1
    fi
  fi

  exit "$status"
}
trap cleanup_reservation EXIT

reservation_arguments=$(printf \
  '{"reservation":{"subnet-id":1,"hw-address":"%s","ip-address":"%s","hostname":"%s"}}' \
  "$hw_address" "$ip_address" "$hostname")
check_success reservation-add "$reservation_arguments"
reservation_added=true

get_arguments="{\"subnet-id\":1,\"identifier-type\":\"hw-address\",\"identifier\":\"$hw_address\"}"
response=$(request reservation-get "$get_arguments")
if ! grep -Eq '"result"[[:space:]]*:[[:space:]]*0([,}]|$)' <<<"$response" || \
   ! grep -Eq "\"hw-address\"[[:space:]]*:[[:space:]]*\"$hw_address\"" <<<"$response"; then
  printf 'FAIL reservation-get: %s\n' "$response" >&2
  exit 1
fi
printf 'PASS reservation-get\n'

check_success reservation-del "$delete_arguments"
response=$(request reservation-get "$get_arguments")
if ! grep -Eq '"result"[[:space:]]*:[[:space:]]*3([,}]|$)' <<<"$response"; then
  printf 'FAIL reservation-get after deletion: %s\n' "$response" >&2
  exit 1
fi
printf 'PASS reservation-get confirms deletion\n'
reservation_added=false
