#!/bin/bash
# Unit test for cold_start_eligibility(): at a cold start (both standbys) the node with the newer data state gets
# the preferred score, the older one -INFINITY, equal states the normal score (no Pacemaker or PostgreSQL needed).
# Usage: bash test/test-cold-start-rank.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
for f in cold_start_eligibility data_state_compare lsn_to_int; do
    code=$(extract $f); [ -n "$code" ] || { echo "FAIL: $f not found in agent"; exit 1; }
    eval "$code"
done
STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
PGDATA="$STORE/data"; mkdir -p "$PGDATA"; touch "$PGDATA/standby.signal"
get_peer_member_name() { echo "$FAKE_PEER"; }
peer_recovery_state() { echo "$FAKE_PEER_REC"; }
resolve_cluster_node_to_hostname() { echo "$1"; }
query_data_state() { if [ -z "$1" ]; then [ -n "$FAKE_LOCAL" ] && echo "$FAKE_LOCAL"; else [ -n "$FAKE_REMOTE" ] && echo "$FAKE_REMOTE"; fi; }
set_promotion_eligibility() { MODE="$1"; }
ocf_log() { :; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
run() { MODE=none; cold_start_eligibility; RC=$?; }

# dmkif T5: local 145/0/48016E20, peer 145/0/48016E98
FAKE_PEER=pgt-b FAKE_PEER_REC=t FAKE_LOCAL="145 0/48016E20" FAKE_REMOTE="145 0/48016E98"; run
check "T5: peer newer -> ineligible" "0 ineligible" "$RC $MODE"
FAKE_LOCAL="145 0/48016E98" FAKE_REMOTE="145 0/48016E20"; run
check "T5 seen from the peer: newer -> preferred" "0 newer" "$RC $MODE"
FAKE_LOCAL="146 0/10000000" FAKE_REMOTE="145 0/48016E98"; run
check "newer timeline wins over a higher LSN" "0 newer" "$RC $MODE"
FAKE_LOCAL="145 0/48016E98" FAKE_REMOTE="145 0/48016E98"; run
check "equal -> normal score (scheduler's choice)" "0 eligible" "$RC $MODE"
FAKE_PEER_REC=f; run
check "peer is primary -> not applicable" "1 none" "$RC $MODE"
FAKE_PEER_REC=t FAKE_REMOTE=; run
check "peer state unreadable -> not applicable" "1 none" "$RC $MODE"
FAKE_PEER= FAKE_REMOTE="145 0/48016E98"; run
check "peer not a member -> not applicable" "1 none" "$RC $MODE"
FAKE_PEER=pgt-b; rm -f "$PGDATA/standby.signal"; run
check "this node is no standby -> not applicable" "1 none" "$RC $MODE"

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
