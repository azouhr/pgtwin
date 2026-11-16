#!/bin/bash
# Unit test for the pair functions (pgtwin_pair_nodes, pair_config_problem,
# pgtwin_peer, pgtwin_peer_member, pgtwin_peer_host, resolve_cluster_node_to_hostname):
# the peer is always the other node of this PostgreSQL cluster, never another
# node of the Pacemaker cluster (doc/STATE_MATRIX.md M5). No Pacemaker needed.
# Usage: bash test/test-pair-peer.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
for f in short_node_name pacemaker_node_names pgtwin_pair_nodes pair_config_problem pgtwin_peer \
         pgtwin_peer_member pgtwin_peer_host resolve_cluster_node_to_hostname mark_peer_unsynced; do
    code=$(extract $f); [ -n "$code" ] || { echo "FAIL: $f not found in agent"; exit 1; }
    eval "$code"
done
command -v xmllint >/dev/null 2>&1 || { echo "SKIP: xmllint not installed"; exit 0; }

# FAKE_NODES: Pacemaker node names in crm_mon order; FAKE_MEMBERS: the members
# among them (crm_node -l state member, the others are lost); FAKE_ME: this node
crm_mon() {
    local n
    echo '<crm_mon><nodes>'
    for n in $FAKE_NODES; do echo "<node name=\"$n\" online=\"true\"/>"; done
    echo '</nodes></crm_mon>'
}
crm_node() {
    local n i=0
    for n in $FAKE_NODES; do
        i=$((i + 1))
        case " $FAKE_MEMBERS " in *" $n "*) echo "$i $n member" ;; *) echo "$i $n lost" ;; esac
    done
}
get_cluster_node_name() { echo "$FAKE_ME"; }
ocf_log() { :; }
OCF_RESKEY_rep_mode=sync
unsynced_attr() { echo pgtwin-unsynced-test; }
node_unsynced_since() { :; }
crm_attribute() { echo "crm_attribute $*" >> "$STORE/attr.log"; }
STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
peer() { pgtwin_peer; echo "rc=$?"; }

ALL4="pg1 pg2 pg3 pg4"; FAKE_MEMBERS="$ALL4"

# Four nodes, two pairs, both node orders (the lab of 2026-11-16 and its reverse)
for order in "pg1 pg2 pg3 pg4" "pg3 pg4 pg1 pg2" "pg4 pg1 pg3 pg2"; do
    FAKE_NODES="$order"
    OCF_RESKEY_node_list="pg1 pg2"
    FAKE_ME=pg1; check "order '$order': pg1 -> pg2" "pg2 rc=0" "$(peer | tr '\n' ' ' | sed 's/ $//')"
    FAKE_ME=pg2; check "order '$order': pg2 -> pg1" "pg1 rc=0" "$(peer | tr '\n' ' ' | sed 's/ $//')"
    OCF_RESKEY_node_list="pg3 pg4"
    FAKE_ME=pg3; check "order '$order': pg3 -> pg4" "pg4 rc=0" "$(peer | tr '\n' ' ' | sed 's/ $//')"
    FAKE_ME=pg4; check "order '$order': pg4 -> pg3" "pg3 rc=0" "$(peer | tr '\n' ' ' | sed 's/ $//')"
    check "order '$order': valid pair config" "" "$(pair_config_problem)"
done

# Membership: only the peer of the own pair counts
FAKE_NODES="$ALL4"; OCF_RESKEY_node_list="pg3 pg4"; FAKE_ME=pg4
FAKE_MEMBERS="pg1 pg2 pg4"; check "pg3 lost, pg1/pg2 members -> pg4 is alone" "" "$(pgtwin_peer_member)"
pgtwin_peer_member >/dev/null; check "pg4 alone -> rc 1" 1 $?
FAKE_MEMBERS="$ALL4"; check "pg3 member -> peer member pg3" "pg3" "$(pgtwin_peer_member)"

# Two nodes without node_list: unchanged behaviour
OCF_RESKEY_node_list=""; FAKE_NODES="pg1 pg2"; FAKE_MEMBERS="pg1 pg2"
FAKE_ME=pg1; check "two nodes, no node_list: pg1 -> pg2" "pg2" "$(pgtwin_peer)"
FAKE_ME=pg2; check "two nodes, no node_list: pg2 -> pg1" "pg1" "$(pgtwin_peer)"
check "two nodes, no node_list: valid" "" "$(pair_config_problem)"
FAKE_MEMBERS="pg2"; check "two nodes, pg1 lost -> pg2 alone" "" "$(pgtwin_peer_member)"

# Four nodes without node_list: refused, no guess
FAKE_NODES="$ALL4"; FAKE_MEMBERS="$ALL4"; FAKE_ME=pg3
check "four nodes, no node_list -> no peer" "rc=1" "$(peer | tr '\n' ' ' | sed 's/ $//')"
case "$(pair_config_problem)" in *"has 4 nodes"*) r=refused ;; *) r="$(pair_config_problem)" ;; esac
check "four nodes, no node_list -> refused" refused "$r"
check "four nodes, no node_list -> not a member peer" "" "$(pgtwin_peer_member)"

# Wrong node_list: three entries, or without this node
OCF_RESKEY_node_list="pg1 pg2 pg3"; FAKE_ME=pg3
check "node_list with three nodes -> no peer" "rc=1" "$(peer | tr '\n' ' ' | sed 's/ $//')"
[ -n "$(pair_config_problem)" ]; check "node_list with three nodes -> refused" 0 $?
OCF_RESKEY_node_list="pg1 pg2"; FAKE_ME=pg3
check "node_list without this node -> no peer" "rc=1" "$(peer | tr '\n' ' ' | sed 's/ $//')"
[ -n "$(pair_config_problem)" ]; check "node_list without this node -> refused" 0 $?

# FQDN in node_list, short names in Pacemaker: peer as Pacemaker names it, host as node_list
OCF_RESKEY_node_list="pg3.lab.example pg4.lab.example"; FAKE_NODES="$ALL4"; FAKE_ME=pg3
check "FQDN node_list: peer is the Pacemaker name" "pg4" "$(pgtwin_peer)"
check "FQDN node_list: host is the node_list entry" "pg4.lab.example" "$(pgtwin_peer_host)"
check "FQDN node_list: valid" "" "$(pair_config_problem)"

# resolve: a node outside node_list is used as-is (no more "first entry")
OCF_RESKEY_node_list="pg3 pg4"
check "resolve pg1 with node_list 'pg3 pg4' -> pg1" "pg1" "$(resolve_cluster_node_to_hostname pg1)"
check "resolve pg4 -> pg4" "pg4" "$(resolve_cluster_node_to_hostname pg4)"

# Record: goes to the own peer; undetermined peer -> refuse (keep sync)
OCF_RESKEY_node_list="pg3 pg4"; FAKE_ME=pg3; rm -f "$STORE/attr.log"
node_unsynced_since() { [ -f "$STORE/attr.log" ] && echo 1; }
mark_peer_unsynced; rc=$?
check "record from pg3 -> rc 0" 0 $rc
case "$(cat "$STORE/attr.log" 2>/dev/null)" in *"-N pg4 "*) r=pg4 ;; *) r="$(cat "$STORE/attr.log" 2>/dev/null)" ;; esac
check "record from pg3 goes to pg4" pg4 "$r"
OCF_RESKEY_node_list=""; rm -f "$STORE/attr.log"
mark_peer_unsynced; check "record with undetermined peer -> rc 1 (keep sync)" 1 $?
check "record with undetermined peer -> nothing written" "" "$(cat "$STORE/attr.log" 2>/dev/null)"

[ $fail -eq 0 ] && echo "ALL PASSED" || { echo "$fail FAILED"; exit 1; }
