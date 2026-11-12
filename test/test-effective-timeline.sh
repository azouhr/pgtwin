#!/bin/bash
# Unit test for local_effective_timeline(): a newer history file counts only if this node's position on its
# checkpoint timeline is not past the switch point (no PostgreSQL needed). Usage: bash test/test-effective-timeline.sh
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/../pgtwin"
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" { p=1 } p { print } p && /^}/ { p=0 }' "$AGENT"; }
for f in local_effective_timeline lsn_to_int; do
    code=$(extract $f); [ -n "$code" ] || { echo "FAIL: $f not found in agent"; exit 1; }
    eval "$code"
done
STORE=$(mktemp -d); trap 'rm -rf "$STORE"' EXIT
PGDATA="$STORE/data"; mkdir -p "$PGDATA/pg_wal"
run_as_pguser() { "$@"; }
ocf_log() { :; }
# fake pg_controldata: FAKE_STATE, FAKE_TLI, FAKE_CKPT, FAKE_MINREC, FAKE_MINTLI
pg_controldata() {
    printf "Database cluster state:               %s\n" "$FAKE_STATE"
    printf "Latest checkpoint location:           %s\n" "$FAKE_CKPT"
    printf "Latest checkpoint's TimeLineID:       %s\n" "$FAKE_TLI"
    printf "Minimum recovery ending location:     %s\n" "$FAKE_MINREC"
    printf "Min recovery ending loc's timeline:   %s\n" "$FAKE_MINTLI"
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fail=$((fail + 1)); fi; }
hist() { rm -f "$PGDATA"/pg_wal/*.history; printf '105\t%s\tno recovery target specified\n' "$1" > "$PGDATA/pg_wal/0000006A.history"; }

# lab 2026-11-12 (test 3b): former primary demoted alone, checkpoint after the switch point
hist 0/F40C0C70
FAKE_STATE="shut down in recovery" FAKE_TLI=105 FAKE_CKPT=0/F40C3158 FAKE_MINREC=0/F40C31D0 FAKE_MINTLI=105
check "demoted primary past the switch point -> diverged (105)" 105 "$(local_effective_timeline)"

# standby that followed: restartpoint on 105 before the switch point
FAKE_STATE="shut down in recovery" FAKE_TLI=105 FAKE_CKPT=0/F4000000 FAKE_MINREC=0/F40C0000 FAKE_MINTLI=105
check "standby before the switch point -> follows 106" 106 "$(local_effective_timeline)"

# 1.8.1 case: crashed standby, minimum recovery point already on the new timeline
FAKE_STATE="in archive recovery" FAKE_TLI=105 FAKE_CKPT=0/F4000000 FAKE_MINREC=0/F4100000 FAKE_MINTLI=106
check "crashed standby, min recovery point on 106 -> 106" 106 "$(local_effective_timeline)"

# primary keeps its checkpoint timeline
FAKE_STATE="in production" FAKE_TLI=105 FAKE_CKPT=0/F4000000 FAKE_MINREC=0/0 FAKE_MINTLI=0
check "primary -> checkpoint timeline" 105 "$(local_effective_timeline)"

# exactly at the switch point: not past it
FAKE_STATE="shut down in recovery" FAKE_TLI=105 FAKE_CKPT=0/F40C0C70 FAKE_MINREC=0/0 FAKE_MINTLI=0
check "position equal to the switch point -> follows 106" 106 "$(local_effective_timeline)"

[ $fail -eq 0 ] && echo "ALL PASSED" || echo "$fail FAILED"
exit $fail
