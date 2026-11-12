# pgtwin v1.8.3 Release Notes

**Release date:** 2026-11-12
**Type:** bug fix release; upgrade recommended for everyone on 1.8.2

## Overview

| # | Problem in 1.8.2 | Impact |
|---|---|---|
| 1 | After a full partition with two primaries, the surviving primary could keep the other side's "not in sync" record | a later cold start (or a lone restart of that node) had no promotion candidate: no primary until someone removed the record |

## 1. The survivor's record

While both nodes run as primary in a full partition (section 5 of the 1.8.2 release notes), each records the
other as "not in sync" (`pgtwin-unsynced-<resource>`) before it relaxes. When the partition heals, one of the two
stays primary and the other is rewound. Whether the record the discarded side wrote on the survivor is still in
the CIB depends on the merge: in our lab it survived when the discarded side was stopped before the heal and
started again afterwards (the documented override), and did not survive when the heal resolved it automatically.

1.8.2 never let a node remove its own record, so the survivor kept it as long as it stayed primary. That is
harmless for the running primary (the record only blocks promotions), but in the next cold start the survivor was
at -INFINITY because of the record and the other node because its data was older: no candidate. The record also
blocked a lone restart of the survivor. It went away only after a switchover, once the survivor was a synchronous
standby.

1.8.3: a primary removes the record on itself once the peer streams from it as synchronous standby. The peer has
then been rewound or rebuilt to this node's history, so the commits the record referred to exist nowhere any
more. A stale primary still cannot drop the record the new primary set for it: the new primary never streams from
it as its synchronous standby.

## Upgrade notes

- Replace the agent with copy + rename (`cp pgtwin pgtwin.new && mv pgtwin.new pgtwin`), also `fence_pgtwin` in
  `/usr/sbin` (only its version string changed).
- A primary that carries such a record removes it with its next monitor while the standby is in sync.
- QUICKSTART "Choosing the primary by hand": after a full partition, start the stopped side again only after the
  heal; started while still cut off, it would be promoted alone again.

## Documentation

QUICKSTART has a new section "Quorum in a two-node cluster". Two nodes cannot have a real quorum (a majority needs
at least three votes); corosync's `two_node: 1` reports a single node as quorate, and in a partition both halves.
pgtwin is built for two data centres, where no independent third vote exists, and relies on fencing and on never
promoting a node that may miss acknowledged commits, not on quorum.

## Tests

Lab: two KVM nodes (openSUSE Tumbleweed, PostgreSQL 17.11, Pacemaker 3.0.3), two knet rings, `fence_virsh` plus
`fence_pgtwin` as the last level, `rep_mode=sync`. Full partitions: all traffic between the nodes, the VIP and the
hypervisor fence blocked on one node.

| Test | 1.8.2 | 1.8.3 |
|---|---|---|
| Full partition, both primary; override: discarded side stopped before the heal, started after it | survivor kept the record; the next cold start had no candidate | survivor: "the peer now follows it as synchronous standby, the record is void: removed"; cold start promotes; survivor's 725 acknowledged commits all present |
| Full partition, both primary, resolved automatically after the heal | record did not survive the merge | same, nothing left over |
| Cold start, the admin wants the older node: `crm node standby <newer>` | - | older node promoted after 17 s, the other rewound after `crm node online` |
| Unit tests (`test-own-record.sh` new, the 1.8.2 ones) | - | all pass |
| `test-pgtwin-ha-suite.sh` (both fence levels running) | 12/12 | 12/12 |
