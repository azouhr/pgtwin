#!/bin/bash
# Unit test for the pgtwin-migrate sanity checks (mig_clusters_valid,
# mig_pgtwin_version_valid, mig_probe_protection_valid, mig_quorum_check) against
# a mocked CIB. No Pacemaker needed.
# Usage: bash test/test-migrate-sanity.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin-migrate"
command -v xmllint >/dev/null 2>&1 || { echo "SKIP: xmllint not installed"; exit 0; }
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
for f in mig_short_name mig_clone_primitive mig_primitive_agent mig_primitive_node_list mig_clone_running_nodes \
         mig_cluster_nodes mig_in_list mig_clusters_valid mig_pgtwin_version_valid mig_probe_protection_valid \
         mig_quorum_check mig_sanity_checks; do
    code=$(extract $f); [ -n "$code" ] || { echo "FAIL: $f not found in agent"; exit 1; }
    eval "$code"
done
eval "$(grep '^PGTWIN_MIN_VERSION=' "$AGENT")"
OCF_SUCCESS=0; OCF_ERR_CONFIGURED=6
STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
ocf_exit_reason() { echo "$*" > "$STORE/reason"; }
ocf_log() { echo "$*" >> "$STORE/log"; }

# Mocked cluster. NL17/NL18: node_list values (unset: no nvpair); AGENT18: agent
# type of the PG18 primitive; RUN18: nodes running pg18-clone; CONS: constraints
nvpair() { [ -n "$2" ] && echo "<nvpair name=\"node_list\" value=\"$2\" id=\"$1-nl\"/>"; }
cibadmin() {
    case "$*" in
        *resources*)
            echo "<resources>"
            echo "<clone id=\"postgres-clone\"><primitive id=\"postgres-db\" class=\"ocf\" provider=\"heartbeat\" type=\"pgtwin\"><instance_attributes>$(nvpair postgres-db "$NL17")</instance_attributes></primitive></clone>"
            echo "<clone id=\"pg18-clone\"><primitive id=\"pg18-db\" class=\"ocf\" provider=\"heartbeat\" type=\"${AGENT18}\"><instance_attributes>$(nvpair pg18-db "$NL18")</instance_attributes></primitive></clone>"
            echo "</resources>" ;;
        *constraints*)
            echo "<constraints>"
            local c
            for c in $CONS; do
                echo "<rsc_location id=\"l-$c\" rsc=\"${c%@*}\" node=\"${c#*@}\" resource-discovery=\"never\" score=\"-INFINITY\"/>"
            done
            echo "</constraints>" ;;
    esac
}
crm_mon() {
    local n
    echo "<crm_mon><nodes>"; for n in pg1 pg2 pg3 pg4; do echo "<node name=\"$n\"/>"; done; echo "</nodes><resources>"
    echo "<clone id=\"postgres-clone\"><resource id=\"postgres-db\"><node name=\"pg1\"/></resource><resource id=\"postgres-db\"><node name=\"pg2\"/></resource></clone>"
    echo "<clone id=\"pg18-clone\">"; for n in $RUN18; do echo "<resource id=\"pg18-db\"><node name=\"$n\"/></resource>"; done; echo "</clone>"
    echo "</resources></crm_mon>"
}
corosync-quorumtool() { echo "Expected votes:   $VOTES"; }
crm_attribute() { echo "$POLICY"; }
mkdir -p "$STORE/ocf/resource.d/heartbeat"; OCF_ROOT="$STORE/ocf"
agent_version() { printf '#!/bin/sh\n#\n# Version: %s\n' "$1" > "$OCF_ROOT/resource.d/heartbeat/pgtwin"; }

OCF_RESKEY_source_cluster=postgres-clone; OCF_RESKEY_target_cluster=pg18-clone
good() {
    NL17="pg1 pg2"; NL18="pg3 pg4"; AGENT18=pgtwin; RUN18="pg3 pg4"; VOTES=4; POLICY=ignore
    CONS="postgres-clone@pg3 postgres-clone@pg4 pg18-clone@pg1 pg18-clone@pg2"; agent_version 1.8.4
    OCF_RESKEY_target_cluster=pg18-clone; rm -f "$STORE/reason" "$STORE/log"
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
reason_has() { grep -q -- "$1" "$STORE/reason" 2>/dev/null && echo yes || echo "no: $(cat "$STORE/reason" 2>/dev/null)"; }

good; mig_sanity_checks; check "lab configuration passes" 0 $?
check "lab configuration: no warning" "" "$(cat "$STORE/log" 2>/dev/null)"

good; NL18=""; mig_sanity_checks; check "target without node_list -> refused" 6 $?
check "  reason names pg18-db" yes "$(reason_has 'pg18-db (clone pg18-clone) needs node_list')"
good; NL17="pg1 pg2 pg3"; mig_sanity_checks; check "node_list with three nodes -> refused" 6 $?
good; NL18="pg2 pg3"; RUN18="pg3"; mig_sanity_checks; check "node in both node_lists -> refused" 6 $?
check "  reason names pg2" yes "$(reason_has 'pg2 is in the node_list of both')"
good; RUN18="pg3 pg2"; mig_sanity_checks; check "clone runs outside its node_list -> refused" 6 $?
good; AGENT18=Dummy; mig_sanity_checks; check "target is not pgtwin -> refused" 6 $?
good; OCF_RESKEY_target_cluster=postgres-clone; mig_sanity_checks; check "source = target -> refused" 6 $?
good; OCF_RESKEY_target_cluster=nosuch-clone; mig_sanity_checks; check "unknown clone -> refused" 6 $?
good; NL17="pg1.lab.example pg2.lab.example"; mig_sanity_checks; check "FQDN node_list -> passes" 0 $?

good; agent_version 1.8.3; mig_sanity_checks; check "pgtwin 1.8.3 -> refused" 6 $?
good; agent_version 1.8.10; mig_sanity_checks; check "pgtwin 1.8.10 -> passes (version sort)" 0 $?
good; agent_version 1.9.0; mig_sanity_checks; check "pgtwin 1.9.0 -> passes" 0 $?
good; rm -f "$OCF_ROOT/resource.d/heartbeat/pgtwin"; mig_sanity_checks; check "pgtwin missing -> refused" 6 $?

good; CONS="postgres-clone@pg3 postgres-clone@pg4 pg18-clone@pg1"; mig_sanity_checks; check "probe protection missing for pg18-clone@pg2 -> refused" 6 $?
check "  reason names pg18-clone@pg2" yes "$(reason_has 'pg18-clone@pg2')"
good; CONS="postgres-clone@pg3 postgres-clone@pg4 pg18-db@pg1 pg18-db@pg2"; mig_sanity_checks; check "protection on the primitive instead of the clone -> passes" 0 $?

good; POLICY=""; mig_sanity_checks; check "4 votes, policy unset -> passes" 0 $?
case "$(cat "$STORE/log" 2>/dev/null)" in *"4 votes"*) r=warned ;; *) r="$(cat "$STORE/log" 2>/dev/null)" ;; esac
check "  ... with a warning" warned "$r"
good; VOTES=2; POLICY=""; mig_sanity_checks; check "2 votes, policy unset -> no warning" "" "$(cat "$STORE/log" 2>/dev/null)"

[ $fail -eq 0 ] && echo "ALL PASSED" || { echo "$fail FAILED"; exit 1; }
