# pgtwin state matrix (draft)

**Status:** draft for review, not part of a release. Rows marked *hypothesis* come from reading the code and are
not verified in a lab yet; lab results are in section 9.

## 1. Purpose

Every fix so far closed a gap in one state or in one step between two states (stall, sick standby, lone start,
partition, own record). Each was found separately, mostly by a test that happened to hit it. This document lists
the states of a pgtwin cluster on purpose: for each one what the primary may do, who may become primary next, what
pgtwin does, and which test covers it. A row without a test is a gap in the test plan; a row whose behaviour breaks
a rule is a gap in the agent.

## 2. Rules

The rules are the same in every state; the actions that satisfy them differ.

| | Rule |
|---|---|
| **R1** Consistency | Every commit the primary has acknowledged exists on every node that may become primary next (a *candidate*). |
| **R2** One writer | At most one node acknowledges commits. A second primary that cannot acknowledge (waiting for its synchronous standby) does not break R2. Accepted exception: a full partition in which both sides confirm the other as gone (last resort, section 5.4). |
| **R3** Availability | The primary acknowledges commits unless R1 forbids it, i.e. only while a candidate exists that has not confirmed the commit. A node is promoted when the primary is gone and a candidate exists. |

The invariant of `DESIGN_STALL_SAFE_SYNC.md` ("never acknowledge without the synchronous standby unless there is
proof that it is gone") is how R1 is kept in the healthy state: as long as the standby is a candidate, the primary
waits for it. Once the standby is *recorded* (`pgtwin-unsynced-<rsc>`) it is no candidate, and R3 says waiting for
it protects nothing.

Terms:

- **Candidate:** a running standby that is not recorded and not ruled out by the lone start rule or the data state
  comparison.
- **Record:** `pgtwin-unsynced-<rsc>` on a node, written by the primary before it stops waiting for it; removed only
  by a primary once that node is its synchronous standby and has flushed past the recorded point.
- **Proof that the standby is gone:** post-stop notification (sent after a confirmed stop or fence); peer offline and
  clean in the CIB (with fencing); without fencing peer offline and its PostgreSQL unreachable for
  `PEER_GONE_WINDOW` (6 s); promote.

## 3. Dimensions

| Dimension | Values |
|---|---|
| Role per node | primary, standby, stopped, fenced / unknown, frozen |
| `synchronous_standby_names` on the primary | standby's name, `'*'`, `''` |
| Standby's walsender on the primary | none, `catchup`, `streaming` (only `streaming` counts as synchronous for PostgreSQL) |
| Record | none, on the peer, on the primary itself |
| Connections | all up; replication only down; cluster rings down, PostgreSQL up; full partition; fence device unreachable |
| Membership | 2 nodes (`two_node`); 4 nodes (second pgtwin pair: migration or permanent companion); node waiting in `wait_for_all` |
| Other walsenders | none; logical subscriber (`pgtwin-migrate`, or a permanent companion on another version or product) |
| Operation in progress | start, stop, promote, demote, notification, fencing pending |

The full cross product is large, but most combinations are impossible or behave like another row. The tables below
list the reachable states grouped by situation. Column "Ack" = may the primary acknowledge commits.

Status: **ok** (behaves as the rules say), **gap** (breaks R1, R2 or R3), **hypothesis** (gap from code reading,
not verified), **accepted** (breaks a rule by design).

## 4. Two nodes, standby side

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| S1 | Healthy: standby streaming, sync on its name, no record | after the standby confirms | standby | monitor keeps the name | ok | HA suite |
| S2 | Standby stopped or fenced (confirmed) | yes, alone | none | post-stop: record, then `''` | ok | DESIGN 9.4 |
| S3 | Standby starting, recorded, not streaming yet (`catchup` or connecting) | **no**: post-start set `'*'` | none | post-start `enable_sync_replication` | **gap** (R3): writes wait for a node that is no candidate. Sick standby: one block per restart until `migration-threshold`; healthy standby: a block during every catch-up after a planned stop | dmkif 1.8.2 section 7, `tc-standby-nostream.sh` |
| S3' | Same, proposed fix | yes, alone | none | post-start does not enable sync while the peer is recorded; monitor sets the name once `streaming` | proposed | to write |
| S4 | Standby streaming, recorded | after the standby confirms | none until the record is removed | monitor sets the name, removes the record after the flush past the target | ok | DESIGN 9.4 |
| S5 | Standby starting, not recorded (cold start, after a clean switchover, record removed by hand) | waits during `catchup` | standby | post-start `'*'` | ok (R1: the standby is a candidate) | - |
| S6 | Standby running, cannot stream (sick), sync on its name | no | standby (not recorded yet) | standby fails its monitor after `replication_failure_threshold` cycles, stop, then S2 | ok, bounded block (about threshold x interval) | DESIGN 9.4 |
| S7 | Standby flapping: streams one monitor cycle, breaks again | no after each tightening | none while recorded | monitor tightens on the first `streaming`, block until the next stop | open: one block per flap; hysteresis (two `streaming` observations) not decided | - |
| S8 | Standby node frozen, walsender still listed | no | standby | node lost, fence, post-stop ends the walsender, S2; without fencing: relax after `PEER_GONE_WINDOW` | ok | DESIGN 9.4 |

## 5. Two nodes, primary side and connection faults

### 5.1 Primary failure and switchover

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| P1 | Primary crashed or fenced, standby healthy | - | standby | promote, record the old primary before relaxing | ok | HA suite |
| P2 | Primary fails while the standby is recorded | - | none | standby stays at -INFINITY, operator decides (QUICKSTART "Choosing the primary by hand") | ok (R1 before R3) | DESIGN 9.4 |
| P3 | Switchover | old primary: no new commits after the demote | target | clean demote; record removed after the clean stop if the target received past the shutdown checkpoint | ok | HA suite |
| P4 | Primary frozen, standby promoted (A' and B') | A': no, waits for its standby | B' runs | A' steps down when it sees B' on a newer timeline; Pacemaker demotes it after the cancel timeout (120 s) | ok as long as A' was in sync when it froze | DESIGN 8, dmkif 1.8.2 section 4 |
| P5 | Like P4, but A' was primary/async when it froze | **yes, A'** | B' runs | A' acknowledges until it steps down | accepted? A' had no candidate at the freeze; B' was promoted only by an operator or the lone start rule. To discuss | - |

### 5.2 Replication link down, cluster rings up

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| C1 | Standby cannot reach the primary's port 5432 | no until S6 ends | standby | S6, then S3 (today) or S3' | as S3 | dmkif 1.8.2 section 7 |

### 5.3 Cluster rings down, PostgreSQL up (dmkif finding E)

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| C2 | Both rings down, fence race | no until the fence | standby | winner fences the loser; primary wins: post-stop, S2 | ok | DESIGN 9.8 |
| C3 | Loser rebooted, starts alone, variant A | primary on the other node: yes | none | startup fence of the healthy primary; lone start rule: not primary/async, stays standby | ok for R1, costs availability while the fault lasts | DESIGN 9.8, dmkif E |
| C4 | Same, variant B | yes | none | `wait_for_all`: probes only, no fence | ok | dmkif 1.8.2 |

### 5.4 Full partition and fence devices

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| C5 | No fence device can confirm, no `fence_pgtwin` | no (fencing pending) | - | waits for `stonith_admin --confirm` | ok, availability by operator | - |
| C6 | Full partition, `fence_pgtwin`, gateway on both sides | both | - | both confirm, both primary; heal: older timeline rewound, its commits lost | **accepted** (R2 exception) | DESIGN 9.8 |
| C7 | Same, one side lost its gateway, `isolation_action=demote` | the side with gateway | - | cut-off side never confirms, demotes | ok | DESIGN 9.8 |
| C8 | Cut-off primary that can still reach a fence device (`isolation_action=demote`) | - | - | it may win the fence race and then demote itself: no primary | **gap** (R3); idea: fence delay depending on the gateway | dmkif 1.8.2 section 5 |
| C9 | `fence_pgtwin` at startup, ping attribute not yet set | - | - | never confirms (unset is not a checked gateway) | **gap** (R3) with variant A; idea: agent checks the gateway itself while the attribute is missing | dmkif 1.8.2 question 2 |

## 6. Starts

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| T1 | Cold start, both nodes | - | node with newer data | `cold_start_eligibility`: newer +5000, older -INFINITY | ok | DESIGN 9.9 |
| T2 | Cold start, newer node recorded | - | none | no primary until the operator decides | ok since 1.8.3 when the record is void (own record) | RELEASE 1.8.3 |
| T3 | Node starts alone, was primary/async | - | itself | startup fence (variant A) or `cancel_wait_for_all` (variant B), then promote | ok | DESIGN 9.8 |
| T4 | Node starts alone, was standby or primary/sync | - | none | stays standby; override `pgtwin-promote-alone-<rsc>` | ok | DESIGN 9.8 |
| T5 | Node waiting in `wait_for_all` | - | - | probes only | ok | lab 2026-11-12 |
| T6 | Second node joins with `crm cluster join` | unchanged | unchanged | crmsh deletes `no-quorum-policy=ignore` (with four nodes also resets `priority-fencing-delay`, `rsc_defaults priority` and recalculates `fencing-timeout`) | documented in 1.8.3 and in README-pgtwin-migrate; a check in the agent is open | lab 2026-11-12, 2026-11-15 |
| T7 | New pair, first standby start while the first node is still promoting | - | the promoting node | standby start finds no primary ("unable to discover primary"), fails, retried after `failure-timeout` (about 5 min) | ok for R1/R2 (nothing is written); delay only. Documented workaround: `crm resource cleanup` | lab 2026-11-15 |
| T8 | Agent file replaced in place while a monitor runs | - | - | bash reads the half-written file: syntax error, monitor returns "Invalid parameter" (hard), Pacemaker bans the node; on the primary this moves the primary | operation: install to a new file and rename (docs since 1.8.4); `make install` and RPM are safe | lab 2026-11-16 |
| T9 | Two independent promotions from the same timeline (here: pg4 at 0/3AF2430, later pg3 at 0/3B09CA8, both to TL3) | - | the promoted one | the other node starts as standby: same timeline number, pgtwin does not rewind; the walreceiver fetched the primary's `00000003.history` over its own, after that pg_rewind also reports "same timeline, no rewind required"; the standby cannot stream and fails after 5 cycles | **gap**: the history is lost; only a new basebackup repairs it | lab 2026-11-16 |

## 7. Four nodes and logical subscribers

A second pgtwin pair in the same cluster is not only a migration step: fed by logical replication, it can stay as
a permanent asynchronous companion, on the same PostgreSQL version or on another version or product (logical
replication works across versions, physical replication does not). These rows are therefore regular states.

M3 and M4 concern every walsender on the primary that is not the pgtwin peer. A logical subscriber is the case
pgtwin-migrate creates; an additional physical standby of the same version (cascading or direct) would be
affected the same way, and would be chosen by `'*'` just as readily.

| ID | State | Ack | Candidates | pgtwin does | Status | Test |
|---|---|---|---|---|---|---|
| M1 | 4 members, `two_node` off, quorum 3 | yes | standby of each pair | default policy: 2 of 4 lose quorum, both pairs stop; `ignore`: fencing decides | variant A required; variant B cannot work with a permanent companion | dmkif 1.8.2 discussion |
| M2 | Logical subscriber streaming, sync on the standby's name | after the physical standby confirms | standby | the name excludes the subscriber | ok | - |
| M3 | Other walsender streaming, standby cannot stream: the fallback in `get_safe_synchronous_standby_names` sets `'*'` (also post-start) | **yes, confirmed only by the other walsender** | none in practice: the standby's own monitor sets its score to -INFINITY while it does not stream | the standby is not recorded; it is kept from promotion only by its own veto (reboot lifetime, reset as soon as it streams) | **gap, confirmed** (lab 9.1): R1 rests on the veto alone, not on the record; no hint for an operator who overrides. Failover with loss not reproduced: the veto held | lab 2026-11-13 |
| M4 | Physical standby stops while another walsender streams | `'*'`: yes, via the other walsender; standby's name: **no** | none (stopped) | post-stop counts the other walsender as "other standby still streaming": no relax, no record | **gap, confirmed** (lab 9.2): with `'*'` the primary acknowledges for minutes without the standby and without a record; with the name a planned standby stop (`crm node standby`) blocks writes until the standby is back | lab 2026-11-13 |
| M5 | Peer detection with 4 members | - | - | 1.8.3: the first other node of the whole cluster (`crm_mon`, `crm_node -l`, "first `node_list` entry" fallback). 1.8.4: one source, `pgtwin_pair_nodes`/`pgtwin_peer`: the other node of `node_list`; `node_list` required with more than two cluster nodes | **fixed in 1.8.4** (9.5). 1.8.3: a pair got a node of the other pair as peer, its real standby was never recorded, 481 acknowledged commits lost in test B2 (9.4) | `test/test-pair-peer.sh`; lab 2026-11-16 |
| M6 | Migration nodes stopped for a while | yes | standby | the logical subscription waits; its slot keeps WAL on the primary | ok; disk usage to watch | - |

## 8. Gaps and open points

| # | Row | Kind | Direction |
|---|---|---|---|
| G1 | S3 | R3 | post-start: no sync while the peer is recorded (S3') |
| G2 | M3 | R1, confirmed | never set `'*'`; use the standby's name, otherwise keep waiting or record and relax |
| G3 | M4 | R1/R3, confirmed | post-stop and the relax rules count only walsenders of the pgtwin peer |
| G4 | M5 | R1, confirmed | **done in 1.8.4**: peer = the other node of `node_list`, required with more than two nodes |
| G5 | C8 | R3 | fence delay depending on the gateway |
| G6 | C9 | R3 | `fence_pgtwin` checks the gateway itself while the attribute is missing |
| G7 | S7 | R3 | hysteresis before tightening, only if a test shows the need |
| G8 | P5 | R2 | decide whether a frozen primary/async counts as accepted |
| G9 | T6, M1 | operation | warning when there are more than two voters and `no-quorum-policy` is not `ignore` |
| G10 | T7 | operation | standby start waits (within its timeout) for a promote in progress instead of failing |
| G11 | T8 | operation | documented; optionally a check in the monitor that the agent file is complete (not planned) |
| G12 | T9 | R1 (other node's branch) | before starting as standby, compare the own end of WAL with the switch point in the primary's history file for the own timeline (divergent if the own position on that timeline is past the switch point, or the own switch point differs); then rewind with the correct history, or rebuild |

## 9. Lab results 2026-11-13

Two nodes (pg1 primary, pg2 sync standby, 1.8.3 agent, `fence_virsh` plus `fence_pgtwin`). As the extra
walsender, `pg_receivewal --synchronous` ran on the primary (physical, `wal_level=replica`). A logical subscriber
was not tested (it would need `wal_level=logical`). PostgreSQL treats every walsender whose `application_name`
matches `synchronous_standby_names` as a candidate, logical ones included. Write load: one insert every 0.2 s,
logging each acknowledged id.

### 9.1 M3: `'*'` with the standby cut off

- pg2 cut off from pg1:5432 (reject on pg1, walsender ended) at 17:36:21. Six seconds later the primary monitor
  found no name match among the streaming walsenders and set `'*'`. `pg_receivewal` became `sync`, and the load
  went on.
- pg2 failed its monitor after 5 cycles. Post-stop: "standby on pg2 stopped, but 1 other standby(s) still
  streaming, synchronous replication unchanged". pg2 was never recorded.
- Second run with `pcmk_reboot_action=off`, so the fenced primary stays off: pg2 had id 277, pg1 had acknowledged
  up to 451, and pg1 was destroyed. pg2 was **not** promoted ("no Promoted peer is online: not failing", score
  -INFINITY). The veto comes from its own monitor ("replication not known-good"), not from the record. pg1 started
  again, was promoted again by the data comparison, and all 451 ids were present.
- First run with the normal fence (reboot): pg1 came back within about 70 s, and the comparison promoted it. Same
  result.

### 9.2 M4: planned standby stop with the standby's name set

`pg_receivewal` streaming (async), `synchronous_standby_names='pg2'`, `crm node standby pg2` at 17:45:29.
Post-stop at 17:45:32: unchanged, as above. A test insert hung (timeout). `crm node online pg2` at 17:46:09, and
writes went through again at 17:46:11. Writes were blocked for exactly as long as the standby was away.

### 9.3 M5: peer detection

`get_peer_node_name` run with a simulated `crm_mon` of four nodes (pgtwin01/02 old pair, pgtwin11/12 new pair):
pgtwin01 -> pgtwin02, pgtwin02 -> pgtwin01, **pgtwin11 -> pgtwin01, pgtwin12 -> pgtwin01**. Which pair is hit depends
on the node order. With one order for all nodes, a single "first other node" can never be right for both pairs.

### 9.4 M5 in the four-node lab (2026-11-16)

Four nodes: PG17 pair pg1/pg2 (`postgres-clone`, `node_list="pg1 pg2"`), PG18 pair pg3/pg4 (`pg18-clone`,
`node_list="pg3 pg4"`), all on 1.8.3. pg1/pg2 are first in the node order and get each other as peer. On pg3,
`get_peer_node_name` returns **pg1**:

- Promote of pg3 at 08:24:30: "Promotion safety check: no instance runs on pg1 (stop confirmed by the cluster),
  nothing to check". The check of the real peer pg4 was skipped.
- 08:24:31: "Marked pg1 as not in sync (pgtwin-unsynced-pg18-db)". The record went to pg1, a node that never
  runs `pg18-db`. pg4, the real standby, was not recorded.
- Since then every monitor on pg3 logs "Cluster node 'pg1' not in node_list, using first entry" twice (about 23
  times a minute). `resolve_cluster_node_to_hostname` falls back to the first `node_list` entry, which is pg3
  itself. Every peer probe of pg3 (stale-primary check, relax check, data comparison) asks its own PostgreSQL.
pg1 and pg2 show no such warnings.

Tests with the `pgtwin-migrate` mirror running (PG17 -> PG18, `labdb`), and a writer on pg3 into a pg3-only
database (one insert every 0.2 s, acknowledged ids logged):

- **A: pg1 leaves cleanly** (`crm cluster stop` on pg1). pg3 stays on `'pg4'`: the monitor only relaxes when no
  standby streams, and pg4 streamed. No effect on PG18. The PG17 side was correct (pg2 relaxed and recorded pg1,
  and cleared the record when pg1 was back).
- **B1: pg4 leaves cleanly** (11:36:52). Post-stop on pg3: "Disabling synchronous replication due to standby
  failure", no write blocked. **pg4 was not recorded** (no `pgtwin-unsynced-pg18-db` on pg4; pg1 still had the
  old one). pg3 acknowledged ids up to 1127; pg4 had 646.
- **B2: pg3 leaves cleanly, pg4 starts alone** (11:39:47). The lone start rule did not apply because pg1 is a
  cluster member. The data comparison asked `node_list`'s first entry (pg3, down):
  "decision=promote-peer-unreachable ... Peer pg1 is a cluster member but gave no usable data state within 26s;
  promoting this node, data newer on the peer will be lost". pg4 was promoted at 11:40:33 with ids up to 646:
  **481 acknowledged commits missing (R1)**. With two nodes the record (B1) and the lone start rule (B2) would
  each have prevented this.

### 9.5 M5 retest with 1.8.4 (2026-11-16)

Same four nodes and mirror, pgtwin 1.8.4 on all nodes, writer on pg3 as in 9.4.

- No "not in node_list" warnings any more on any node; no stray records.
- **B1:** pg4 stopped cleanly at 12:15:28: "Marked pg4 as not in sync (pgtwin-unsynced-pg18-db)", then async, no
  write blocked. The record is on pg4 and nowhere else.
- **B2:** pg3 stopped at 12:16:04 (acknowledged up to 1265), pg4 started alone at 12:16:20: pg4 stays Unpromoted
  (score -INFINITY from the record), more than two minutes until pg3 came back.
- pg3 started again: promoted, pg4 streaming in sync after 30 s, the record removed, **1265 of 1265** ids on both
  nodes.

On the way (T8, T9): the agent was deployed by overwriting the file while pg4, then the lone PG18 primary, ran a
monitor. The monitor failed hard, Pacemaker demoted pg4 and promoted pg3 once it started (`promote-peer-unreachable`,
pg4 stopped by then). Both nodes were then on timeline 3 with different histories; pg4 was rebuilt with a
basebackup (its data kept as `data.diverged-20261116`).

## 10. Next steps

1. Review of the rows and of the missing ones.
2. A test per row; rows that need a lab are grouped by setup (two nodes, two nodes with partition tools, four nodes
   with a logical subscriber).
3. Fixes in the order R1 before R3.
