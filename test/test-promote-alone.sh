#!/bin/bash
# Unit test for promotion_alone_blocked() and note_streamed_as_member(): a node whose peer is not a
# cluster member may be promoted only if it was primary/async when it went down, or if it has been a
# healthy, unrecorded standby of the peer as a cluster member since it booted (no Pacemaker needed).
# Usage: bash test/test-promote-alone.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
for f in promotion_alone_blocked note_streamed_as_member; do
    code=$(extract $f); [ -n "$code" ] || { echo "FAIL: $f not found in agent"; exit 1; }
    eval "$code"
done
grep -q '^alone_ok_file() { echo "$(dirname "${PGDATA}")/.pgtwin_last_primary_async"; }' "$AGENT" || { echo "FAIL: alone_ok_file changed"; exit 1; }

STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
PGDATA="$STORE/data"; mkdir -p "$PGDATA"
HA_RSCTMP="$STORE/run"
OCF_RESOURCE_INSTANCE="postgres-db:0"
alone_ok_file() { echo "$(dirname "${PGDATA}")/.pgtwin_last_primary_async"; }
streamed_flag() { echo "${HA_RSCTMP}/pgtwin-${OCF_RESOURCE_INSTANCE%%:*}.streamed"; }
alone_override_attr() { echo "pgtwin-promote-alone-${OCF_RESOURCE_INSTANCE%%:*}"; }
get_cluster_node_name() { echo pg-a; }
get_peer_member_name() { echo "$FAKE_PEER"; }
node_unsynced_since() { echo "$FAKE_UNSYNCED"; }
crm_attribute() { echo "$FAKE_OVERRIDE"; }
ocf_log() { :; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
reset() { rm -rf "$HA_RSCTMP" "$(alone_ok_file)"; FAKE_PEER=; FAKE_UNSYNCED=; FAKE_OVERRIDE=; OCF_RESKEY_rep_mode=sync; }

reset; promotion_alone_blocked; check "alone, standby at boot -> blocked" 0 $?
reset; FAKE_PEER=pg-b; promotion_alone_blocked; check "peer is a member -> data-state comparison decides" 1 $?
reset; OCF_RESKEY_rep_mode=async; promotion_alone_blocked; check "rep_mode=async -> rule not applied" 1 $?
reset; date +%s > "$(alone_ok_file)"; promotion_alone_blocked; check "demoted as primary/async -> eligible alone" 1 $?
reset; FAKE_OVERRIDE=true; promotion_alone_blocked; check "operator override -> eligible" 1 $?
reset; FAKE_OVERRIDE=false; promotion_alone_blocked; check "override not true -> blocked" 0 $?

# Streamed as a cluster member: an ordinary failover later
reset; FAKE_PEER=pg-b; note_streamed_as_member; FAKE_PEER=; promotion_alone_blocked
check "streamed as member, peer lost later -> eligible (record rules apply)" 1 $?
# Streamed without the peer being a member (corosync partition, PostgreSQL reachable: dmkif finding E)
reset; note_streamed_as_member; promotion_alone_blocked; check "streamed, peer not a member -> blocked" 0 $?
# Streamed while recorded as not in sync
reset; FAKE_PEER=pg-b; FAKE_UNSYNCED=1794470000; note_streamed_as_member; FAKE_PEER=; FAKE_UNSYNCED=; promotion_alone_blocked
check "streamed while recorded -> blocked" 0 $?
# Following a primary supersedes an older primary/async state
reset; date +%s > "$(alone_ok_file)"; FAKE_PEER=pg-b; note_streamed_as_member
[ -f "$(alone_ok_file)" ]; check "streaming as member removes the primary/async marker" 1 $?
# Reboot: HA_RSCTMP is empty again
reset; FAKE_PEER=pg-b; note_streamed_as_member; rm -rf "$HA_RSCTMP"; FAKE_PEER=; promotion_alone_blocked
check "streamed before a reboot -> blocked after it" 0 $?

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
