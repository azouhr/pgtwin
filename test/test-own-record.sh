#!/bin/bash
# Unit test for clear_own_unsynced_if_peer_follows(): a primary removes the "not in sync" record on itself (left
# by the peer while both were primary) only once the peer streams from it as synchronous standby.
# Usage: bash test/test-own-record.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
code=$(extract clear_own_unsynced_if_peer_follows); [ -n "$code" ] || { echo "FAIL: function not found in agent"; exit 1; }
eval "$code"
grep -q 'clear_own_unsynced_if_peer_follows "$app"' "$AGENT" || { echo "FAIL: not called from clear_peer_unsynced_if_synced"; exit 1; }

STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
OCF_RESKEY_pgport=5432; OCF_RESOURCE_INSTANCE="postgres-db:0"
PSQL="$STORE/fake-psql"; printf '#!/bin/sh\necho "$FAKE_SYNC_COUNT"\n' > "$PSQL"; chmod +x "$PSQL"
run_as_pguser() { "$@"; }
unsynced_attr() { echo "pgtwin-unsynced-postgres-db"; }
get_cluster_node_name() { echo pg-b; }
node_unsynced_since() { [ -f "$STORE/rec.$1" ] && cat "$STORE/rec.$1"; }
crm_attribute() { local n=""; while [ $# -gt 0 ]; do [ "$1" = "-N" ] && n="$2"; [ "$1" = "-D" ] && rm -f "$STORE/rec.$n"; shift; done; }
ocf_log() { :; }
export FAKE_SYNC_COUNT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
has() { [ -f "$STORE/rec.pg-b" ] && echo yes || echo no; }

echo 1794491460 > "$STORE/rec.pg-b"; FAKE_SYNC_COUNT=0; clear_own_unsynced_if_peer_follows pg_a
check "peer not a synchronous standby -> record kept" yes "$(has)"
FAKE_SYNC_COUNT=; clear_own_unsynced_if_peer_follows pg_a
check "query fails -> record kept" yes "$(has)"
FAKE_SYNC_COUNT=1; clear_own_unsynced_if_peer_follows pg_a
check "peer follows as synchronous standby -> record removed" no "$(has)"
FAKE_SYNC_COUNT=1; clear_own_unsynced_if_peer_follows pg_a
check "no record -> nothing to do" no "$(has)"

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
