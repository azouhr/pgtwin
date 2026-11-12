#!/bin/bash
# Unit test for isolation_action=demote: gateway_lost(), isolated_without_gateway(), primary_isolation_reached()
# (no Pacemaker needed). Usage: bash test/test-isolation.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
for f in gateway_lost isolated_without_gateway primary_isolation_reached isolation_params_valid; do
    code=$(extract $f); [ -n "$code" ] || { echo "FAIL: $f not found in agent"; exit 1; }
    eval "$code"
done

STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
HA_RSCTMP="$STORE/run"
OCF_RESOURCE_INSTANCE="postgres-db:0"
OCF_RESKEY_gateway_attribute=pingd
get_cluster_node_name() { echo pg-a; }
get_peer_member_name() { echo "$FAKE_PEER"; }
crm_attribute() { [ -n "$FAKE_GW" ] && echo "$FAKE_GW"; [ -n "$FAKE_GW" ]; }
ocf_log() { :; }
ocf_exit_reason() { :; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
reset() { rm -rf "$HA_RSCTMP"; FAKE_PEER=; FAKE_GW=; OCF_RESKEY_isolation_action=demote; OCF_RESKEY_isolation_threshold=3; }

reset; FAKE_GW=0;   gateway_lost; check "attribute 0 -> gateway lost" 0 $?
reset; FAKE_GW=100; gateway_lost; check "attribute 100 -> gateway ok" 1 $?
reset;              gateway_lost; check "attribute missing -> unknown, not lost" 1 $?

reset; FAKE_GW=0; isolated_without_gateway; check "alone, gateway lost -> isolated" 0 $?
reset; FAKE_GW=0; FAKE_PEER=pg-b; isolated_without_gateway; check "peer member -> not isolated (ping rule moves the primary)" 1 $?
reset; FAKE_GW=0; OCF_RESKEY_isolation_action=none; isolated_without_gateway; check "isolation_action=none -> never" 1 $?
reset; FAKE_GW=100; isolated_without_gateway; check "alone with gateway -> not isolated" 1 $?

reset; FAKE_GW=0
primary_isolation_reached; r1=$?; primary_isolation_reached; r2=$?; primary_isolation_reached; r3=$?
check "threshold 3: runs 1 and 2 keep the role" "1 1" "$r1 $r2"
check "threshold 3: run 3 gives it up" 0 $r3
reset; FAKE_GW=0; primary_isolation_reached; primary_isolation_reached; FAKE_GW=100; primary_isolation_reached; r=$?
FAKE_GW=0; primary_isolation_reached; r2=$?
check "gateway back resets the count" "1 1" "$r $r2"

reset; isolation_params_valid; check "defaults valid" 0 $?
reset; OCF_RESKEY_isolation_action=stop; isolation_params_valid; check "unknown action rejected" 1 $?
reset; OCF_RESKEY_isolation_threshold=0; isolation_params_valid; check "threshold 0 rejected" 1 $?

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
