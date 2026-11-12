# Design: Stall-safe synchronous replication

**Status:** Implemented in 1.8.0 in a minimal form (section 8), tested in the lab. Sections 1-7 are the
original analysis; section 8 describes what was built and how it differs.
**Date:** 2026-11-10

---

## 1. Problem

A node that stalls (it stops being scheduled but does not die) is the case that redundant rings cannot handle
and that waiting times can only make less likely:

- Live migration or a paused VM (snapshot, host overload),
- multipath failover with `queue_if_no_path`, a hanging NFS/iSCSI path,
- memory pressure, swap storms, kernel soft lockups.

The other node correctly concludes that the stalled node is lost and promotes. When the stalled node runs again,
all of its processes continue at the same time. Two of them do not wait for Pacemaker to reconcile the cluster
state first:

1. **PostgreSQL** is not part of Pacemaker. It still listens on the VIP, serves reads (stale data) and accepts
   commits from the first millisecond after the resume.
2. **Recurring monitors** already scheduled by `pacemaker-execd` fire immediately when they are overdue. The
   pgtwin monitor reads the local, still stale CIB copy and has side effects.

The Pacemaker controller itself does wait: it makes no new decisions before the election, the join with the DC
and the CIB synchronisation. With fencing the node is fenced in exactly that phase.

## 2. Goal and invariant

> **A primary never acknowledges a commit without the confirmation of its synchronous standby, unless it has
> proof that the standby is gone.**

If that holds, a stalled old primary cannot produce acknowledged commits that a later `pg_rewind` discards.
Commits that are not acknowledged are the client's problem in the same way as in any failover: the client sees a
lost connection with an unknown outcome and repeats the request against the new primary.

No waiting time is needed for this. The order of events is guaranteed by Pacemaker (notify, promote and demote
are scheduled by the DC after the reconcile) and by synchronous replication, not by a timeout.

## 3. How PostgreSQL behaves

| Event on a commit that waits for the synchronous standby | Result for the client | Safe? |
|---|---|---|
| Standby confirms | `COMMIT` | yes |
| Standby never confirms (it is now a primary itself) | commit blocks | yes |
| Backend terminated: `pg_ctl stop -m fast/immediate`, `pg_terminate_backend()`, node reset | connection lost, no `COMMIT` | yes, client repeats |
| **Wait cancelled**: `pg_cancel_backend()`, `statement_timeout`, client cancel | **`COMMIT` with a WARNING** "already committed locally, but might not have been replicated" | **no** |

Notes:

- A waiting commit is already written locally and can be visible to other sessions before it is confirmed.
  Such commits are discarded at the reconcile (`pg_rewind`). This is acceptable because they were never
  acknowledged.
- Cancelling is the only way to an acknowledgement without the standby. **The correct reaction to a stalled
  primary is therefore never to cancel, but to turn it into a secondary or switch it off.** Demote (stop, rewind,
  start as standby), a stop and fencing all terminate the waiting backends without acknowledging them.
- pgtwin itself only stops with `pg_ctl -m fast stop`, falling back to `-m immediate`, and never cancels backends
  (checked in 1.8.0).

## 4. The two cases

### 4.1 The primary stalls

1. The standby is promoted (new timeline). The VIP is still configured on the stalled node, because the cluster
   could not remove it.
2. After the resume, commits on the old primary wait for its former standby, which no longer streams from it:
   **nothing is acknowledged**, as long as the old primary does not switch to async by itself (rule 1).
3. The old primary becomes a secondary or goes off: fenced (SBD reset), demoted by Pacemaker after the reconcile,
   or it steps down by itself (rule 2). The waiting sessions are terminated, clients repeat their requests on
   the new primary.

### 4.2 The standby stalls

The primary switches to async after Pacemaker has confirmed that the standby is stopped; writes continue. When the
standby runs again, it catches up and pgtwin switches back to sync (observed in the lab). This case is safe; the
known price of "keep writing without a standby" remains: if the primary is lost before the standby has caught up,
the commits of the async period are lost.

### 4.3 Why the primary cannot decide locally

At the moment the old primary runs again, case 4.1 and case 4.2 look the same from its point of view: the peer is
gone and no standby streams. In 4.2 switching to async is right, in 4.1 it breaks the invariant. The primary
therefore needs **positive proof** before it switches to async, and in a complete partition (no answer at all)
only a third party can provide it: fencing or a quorum device. Waiting times do not replace that; the fencing
delays only decide who wins the fencing race.

## 5. Rules

### Rule 1: asynchronous only with proof (smallest change)

Today the primary monitor switches to async when it sees "No Unpromoted nodes in cluster" (to prevent write
blocking). After a stall this runs before the reconcile, on a stale CIB copy.

Change:

- The monitor no longer relaxes `synchronous_standby_names` by itself. It may still tighten it (standby
  connected and streaming → sync).
- The switch to async happens only in the notify path: `post-stop` of the peer instance, which the DC schedules
  after the reconcile and, with fencing, after the fence.
- Additional proof that allows the switch in the monitor: the peer answers and its PostgreSQL is a standby that
  is not streaming, or is verifiably down.

Risk to test: a standby that fails without a stop notification (instance not recovered by Pacemaker) would block
writes until Pacemaker acts. Expected to be rare; must be covered by the lab matrix.

### Rule 2: the data state decides when both sides meet again

Without fencing (or when fencing fails), Pacemaker finds two promoted instances after the reconcile and demotes
**one of them by score**, not by data state. With a location preference for the old node it can demote the new
primary and discard its commits.

Change:

- The primary monitor checks the peer: if the peer answers as **primary on a higher timeline**, this node is the
  stale one. It removes itself from the Promoted role: VIP off, demote (stop, rewind, standby), without waiting
  for the scheduler.
- The demote of a node must not be accepted if the peer has an older data state (the demote gate from
  `followup/sync-gate-v2`, section 1.3 of the test report, covers part of this).

### Rule 3: client contract (documentation)

- Repeat a request after a lost connection or an error; requests must be safe to repeat (idempotent). This is
  required for every failover, not only for stalls.
- Treat the warning "committed locally, but might not have been replicated" as a failure.
- Do not use `statement_timeout`, `pg_cancel_backend()` or client-side cancel on commit paths.

## 6. Relation to other work

- **Fencing stays.** Redundant rings make a partition less likely; they do not order "standby confirmed gone"
  before "switch to async". With fencing, Pacemaker only reports the standby as stopped after the fence. The
  dual-ring quickstart is corrected accordingly.
- **Sync gate (`followup/sync-gate-v2`, based on patch 0001):** refuses promote and demote without a confirmed
  synchronous state. Rules 1 and 2 are the same family. Open question 1.7 of the test report (strict vs.
  fail-open when no primary is discoverable) is decided together with this design: with rule 1 the cluster
  only runs async with proof, so "strict" becomes the consistent default; `force_promotion` stays the operator
  override.
- **Promotion by data state** (1.7.11) already compares timeline and LSN at promote time; rule 2 applies the same
  comparison when both sides are primary.

## 7. Test plan (lab, before implementation is merged)

| # | Scenario | Expected with rules 1 and 2 |
|---|---|---|
| S1 | `virsh suspend` of the primary for 20 s, `resume`, fencing **off** | standby promoted; old primary acknowledges nothing (no async switch), steps down by itself (rule 2), rejoins via `pg_rewind`; no acknowledged commit lost |
| S2 | as S1, fencing **on** (SBD) | old primary reset after the resume; same result |
| S3 | `virsh suspend` of the standby for 20 s | primary switches to async only after the confirmed stop; back to sync after catch-up |
| S4 | writer with acknowledged commits during S1-S3, compare after reconcile | no acknowledged commit missing |
| S5 | client cancels a waiting commit during S1 | documents the hole of section 3 (`COMMIT` with WARNING) |
| S6 | timing of the first pgtwin monitor after the resume vs. corosync membership change vs. CIB sync | confirms section 1 (monitor runs before the reconcile) |
| S7 | standby PostgreSQL dies, node stays up (rule 1 risk) | writes block only until Pacemaker has stopped the instance |

Every scenario is run with the existing regression set (switchover, crash, staggered shutdown, HA suite).

---

## 8. Implementation (1.8.0)

The behaviour for failing nodes is kept (failover, switch to async, recovery). Only the stall is new: a primary
(A) or standby (B) that stops being scheduled and continues later must be reconciled into the HA setup. Names:
A' = the old primary after the stall, B' = the standby that was promoted in the meantime (and got the VIP).

**Target outcome:** B' survives, because its timeline went on. B' runs asynchronously and keeps serving; A' waits
(its commits are not acknowledged) and is turned into a standby.

### 8.1 What was built

| # | Change | Where |
|---|---|---|
| 1 | The primary monitor only **tightens** `synchronous_standby_names`, it never relaxes it. Relaxing happens in actions Pacemaker schedules after the cluster state is reconciled: **promote** and the **post-stop notification** of the standby | `pgsql_monitor`, `update_application_name_in_config promote` |
| 1a | Exception without fencing: Pacemaker marks a lost node offline and its instance stopped *without a stop action*, so no notification arrives. The monitor may relax when the peer is offline in the CIB **and** its PostgreSQL has been unreachable (no connection at all) for `PEER_GONE_WINDOW` = 6 s over at least two probes (1.8.1; 1.8.0 relaxed on a single failed probe, see 8.5). A peer that answers, or whose server reports an error, is never a reason to relax | `monitor_may_relax_sync()`, `peer_probe()` |
| 1c | With fencing (1.8.1): the post-stop notification Pacemaker sends after the confirmed fence ends the walsender of the stopped peer and relaxes (1.8.0 required an empty `pg_stat_replication`, which the walsender of a fenced standby prevents until `wal_sender_timeout`). Fallback in the monitor: the cluster has recorded the peer as offline **and clean** (fenced or stopped, not just lost). No relax on raw fence events | `pgsql_notify post-stop`, `monitor_may_relax_sync()` |
| 1b | The **start** path may only tighten (a primary restarted by Pacemaker after a stall relaxed here before) | `update_application_name_in_config start` |
| 2 | **Relative promotion score**, transient attribute: base 10 (the floor of #13, so every steady-state score and the stickiness arithmetic are unchanged); right after a promotion the peer's last known score + 10000; back to 10 once a standby is in sync (rep_mode=async: streaming) and the peer is at the base; demote and standby start drop to the base at once. A primary without an in-sync standby keeps its value and never raises it, so a stale primary cannot outgrow the promoted one. Of two primaries after a stall or partition the one promoted last wins the scheduler's demote decision by a margin that no location (50), connectivity (200) or stickiness difference reaches, whichever node is DC. The permanent attribute of earlier versions is removed (it lives in the CIB configuration, where the copy that wins the CIB merge overwrites the other side's value) | `set_promotion_eligibility()` |
| 3 | **Step down (rule 2)**: a primary that finds the peer as primary on a newer timeline marks itself ineligible, stops PostgreSQL (terminates waiting commits without acknowledging them) and returns `OCF_FAILED_PROMOTED`; Pacemaker restarts it as standby | `stale_primary_check()` in the primary monitor |
| 4 | **Never start as a second primary**: a former primary without `standby.signal` starts as standby when another primary is running, and is rewound to it | `pgsql_start` |

### 8.2 What the lab runs showed

The first implementation (only 1 and 3) failed the target in the decisive direction: A' resumed, Pacemaker's
reconcile made **A' the DC within one second** and demoted **B'** by score (location 100 vs 50) before A''s
monitor ran; the rule 2 check additionally saw the walsender entry from before the stall as "streaming" and was
skipped. Points 2 and 4 and 1b come from that run: the decision is made by the scheduler on the merged state, so
the data state has to be in the score; and Pacemaker stops and restarts A' after the stall (its overdue monitor
timed out), where the start path started it as primary again and relaxed to async for two seconds (23
acknowledged commits that were not on B').

A second iteration used `10 + 100 x timeline` as score. It worked, but PostgreSQL's TimeLineID only grows: from
timeline 9000 on Pacemaker's score limit (1,000,000) would have equalised both nodes silently, and a margin of 100
does not outweigh a lost ping (200) of the promoted node. The relative score replaces it. Its first version reset
only on the primary side: for a few seconds the demoted node (monitor every 10 s) still had its bonus while the
primary (monitor every 3 s) had already reset, and Pacemaker switched over to the "better" standby. Resetting on
demote/standby start and only when the peer is at the base removed that.

### 8.3 Results

Lab: two KVM nodes, PostgreSQL 17.11, Pacemaker 3.0.3, writer on the stalled node via local socket, every
acknowledged id checked on the final primary.

| Scenario | Result |
|---|---|
| Stall of A (40 s), no fencing, A = node with location preference | B' survives, A' standby after 22 s, 0 acknowledged commits lost, nothing acknowledged after the resume |
| Stall of A (40 s), no fencing, A = other node | same, A' standby after 23 s |
| Stall of A (130 s), SBD | B' promoted after the fence, A' reset by SBD at the resume, 0 lost |
| Stall of B (45 s), no fencing | primary async after 17 s (writes blocked 17 s), back to sync 9 s after the resume, 0 lost |
| Standby crash, SBD | async after the fence: writes blocked 63 s (= fence time with the `crm cluster init` delays) |
| Standby crash, no fencing | async 1 s after the standby is offline (before 1a: never, writes blocked) |
| Regression: switchover (standby, move), primary killed with blocked restart, HA suite | unchanged (19-26 s, 37 s failover, rejoin via pg_rewind) |
| Ping failover in steady state (`crm_simulate`, primary `pingd=0`) | fails over, 210 vs 260 (same as before 1.8.0) |
| Stall of A (40 s), no fencing, A has location preference **and** B' lost its ping | B' survives the reconcile (bonus), afterwards the ping rule moves the primary to the connected node as a normal switchover; 0 lost |
| Switchover, scores sampled every 2 s | new primary 10010, old primary 10 at once, both 10 four seconds after the standby is in sync; one promote, no flapping |

### 8.4 Open points

- **Writes block while the standby is being fenced**: detection plus fence time (SBD with the `crm cluster init`
  delays: 63 s; power fencing with token 3000: 13 s, see 8.5). In 1.8.0 the block could be unbounded (8.5,
  finding B).
- **A standby that runs but does not stream** (authentication, slot, rewind trouble): the monitor no longer
  relaxes, writes block until the standby's own recovery stops its instance. Before, the primary relaxed within
  one monitor interval. Option: relax when the condition persists longer than the promote timeout (a reachable
  standby could otherwise be in the middle of its promotion after a stall of this node). Decided in 1.8.2: no
  relax next to a running standby; the standby fails itself and is stopped (section 9).
- **Full partition**: by design two independent regions; on healing the newer timeline wins (score and rule 2),
  the other side's writes of the partition are discarded by pg_rewind. Both sides promoted from standby during
  the partition (same timeline number, different data) needs an operator.
- Found during the tests and fixed in 1.8.1: a standby that crashed seconds after a timeline switch could not
  reach a consistent state and failed every start. Cause: a false timeline divergence on the standby start led to
  `pg_rewind`, whose single-user crash recovery ended the standby's recovery on the primary's timeline (see
  CHANGELOG 1.8.1).
- After the resume a stalled primary holds the VIP until it is reset or demoted. Clients whose ARP cache still
  points to it wait (seen for 40 s by dmkif) although the new primary serves; nothing is acknowledged there.

### 8.5 Findings from dmkif's test run and changes in 1.8.1

dmkif ran the full matrix on 1.8.0 in two labs (SBD; dual knet rings without fencing). Four findings, all
reproduced or traced in the code:

| | Finding | Cause | 1.8.1 |
|---|---|---|---|
| A | Both rings down, no fencing: 4 acknowledged commits lost | rule 1a relaxed on one failed probe while the peer was in the middle of its promotion | probe classified (answers / server error / unreachable), relax only after 6 s unreachable over two probes, one probe per monitor run |
| B | SBD, standby frozen: writes blocked 199 s (until it came back; unbounded if it never does) | post-stop required an empty `pg_stat_replication`; the fenced standby's walsender stays listed until `wal_sender_timeout`, and nothing relaxed afterwards | rule 1c |
| C | Upgrade from 1.7.13: primary demoted, 93 s without primary | permanent score deleted before the transient one was in the CIB | transient first, permanent removed once the transient value is visible |
| D | Every switchover 60 s slower | since 1.8.0 discovery via the VIP succeeds and the standby streamed from the VIP; at the demote the VIP goes first, the connection hangs, the old primary's shutdown waits for its walsender | discovery returns the node behind the VIP (same `pg_postmaster_start_time()`); standbys on the VIP are moved to the node by the monitor |

Found on the way: the promotion safety check queried the primary as the postgres role without a password, and the
replication user without `pg_read_all_stats` cannot see `sync_state`. In setups following QUICKSTART the check
therefore blocked every promotion while the old primary still answered (only partitions are affected; a dead
primary fails open). Fixed (replication user, QUICKSTART grant, explicit log message).

Lab (two KVM nodes, two knet rings, `fence_virsh` power fencing via the hypervisor, token 3000 ms, no SBD; writer
over the VIP from the surviving node, every acknowledged id checked on the final primary):

| Scenario | Result |
|---|---|
| Standby frozen, fencing (B) | fenced 4 s after the loss, relaxed 2 s later: writes blocked 12.8 s (1.8.0: until the standby returns), 0 lost |
| Primary frozen 40 s, fencing | membership lost 6.9 s, fence incl. `priority-fencing-delay` 8.6 s, promote 1.4 s: write gap 20.3 s, 0 lost (before the safety-check change below: 22.4 s, promote 5 s) |
| Both rings down, fencing | primary fences the standby first (priority delay), relaxed right after: write gap 3.2 s, 0 lost |
| Both rings down, no fencing (A) | peer promotes, primary never relaxes, steps down 1 s later (rule 2), 0 lost; with the primary's probes blocked for 5 s during the peer's promotion (the race of finding A): "unreachable, waiting", then rule 2, 0 lost |
| Standby powered off, no fencing | relaxed after 6 s unreachable: write gap 18.6 s (cost of the window), 0 lost |
| Upgrade state (only the permanent score) on the primary, 5 runs (C) | permanent removed after the transient value, no scheduler action |
| Standby streaming from the VIP (D) | moved to the node by the next monitor; switchover 20 s (dmkif 1.8.0: 69-77 s), 0 lost |
| `test-pgtwin-ha-suite.sh` | 12/12 |

The promote after a fenced primary took 5 s: the promotion safety check searched the old primary (VIP and node,
2 s connect timeout each) before failing open. With fencing it now skips the search when the cluster has recorded
the former primary as offline and clean (promote 1.4 s), and in any case when the former primary is a member
with no instance running (switchover: write gap 18.0 -> 15.8 s). Without fencing a lost node is always asked:
there it counts as clean on blind faith while its primary may still run.

## 9. Sick standby and the "not in sync" record (1.8.2)

### 9.1 Decision

dmkif asked to relax `synchronous_standby_names` when a standby runs but does not stream for longer than the
promote timeout (k3s: writes blocked without a bound are worse than a short asynchronous window). Declined in that
form:

- A standby that runs but does not integrate is **sick, not dead**. Relaxing next to it leaves a running
  promotion candidate whose data is behind; every later event (primary failure, restart, end of a partition) can
  then go either way.
- The cluster makes it dead instead: the standby fails its own monitor, Pacemaker stops it (and fences the node
  if the stop fails), and the primary relaxes on the post-stop notification, a proof it already accepts
  (rule 1c). The primary never relaxes on its own observation of a reachable peer, so the stale-view problem (the
  peer might be in the middle of its promotion) does not arise.
- A stop is also the clearer state for the admin: a failed action with a reason, and a banned instance after
  `migration-threshold` failures if the start cannot repair it.

The relax after a stop still left a gap: the standby can come back, stream but not yet be caught up, and be
promoted when the primary fails in that window (`no_primary_in_cluster` keeps it eligible). Then the commits the
primary acknowledged without it are lost. In a long asynchronous period (dmkif: 17 days without a working
standby) that would be all of them.

### 9.2 Rules

1. **Sick standby fails itself.** After `replication_failure_threshold` consecutive monitor cycles without
   streaming, and only while a Promoted peer is an online member, the standby monitor returns an error. Without a
   Promoted peer it does not (it may be the next primary). Repair moves to the start: timeline divergence ->
   `pg_rewind`, removed WAL (detected by the monitor before failing, passed to the start) or a stuck WAL position
   -> `pg_basebackup`. A standby that cannot be repaired (authentication) is banned after `migration-threshold`.
2. **Record before relaxing.** Before a primary with `rep_mode=sync` writes an empty
   `synchronous_standby_names` (post-stop notification, monitor rules 1a/1c, promote), it writes the permanent
   node attribute `pgtwin-unsynced-<rsc>` (relax time) on the peer and waits until it is in the CIB. If it cannot
   be written, the primary keeps waiting. A primary that runs asynchronously for any other reason (cold start)
   writes it with its next monitor.
3. **A recorded node is never a candidate.** `set_promotion_eligibility` keeps it at -INFINITY whatever the
   caller found (also in the no-primary case), and promote refuses. Recovery after a loss of the primary then
   needs an operator, who decides whether the commits since the recorded time may be lost (QUICKSTART).
4. **Only the primary clears it**, once the peer streams as synchronous standby and has flushed past the WAL
   position seen when it was first found in sync (all commits acknowledged without it lie below), usually in the
   same monitor run. A primary that demotes cleanly also clears it when the peer streamed from it right before
   the stop and has received past its shutdown checkpoint: the walsender ships all WAL before the shutdown ends,
   so every commit lies below that checkpoint. Without this, a switchover seconds after a rejoin found the target
   still recorded and the cluster ended without primary (HA suite, first 1.8.2 run). A node never clears its own
   record: a stale primary (A') would otherwise drop the record B' set for it.

The record is permanent so it survives a reboot of either node. Setting it too often is harmless (it is cleared
seconds after the standby is back in sync); setting it too rarely would lose commits, hence "record first".

### 9.3 Server authentication (`conn_require_auth`)

All proofs above come from the cluster (corosync, authenticated). The agent's own PostgreSQL connections
(probes, discovery, safety check, streaming, `pg_rewind`, `pg_basebackup`) did not verify the server: libpq
accepts a server that skips authentication. Whoever takes a node address or the VIP could make a primary step
down (rule 2), pass the safety check, or serve a standby wrong WAL or a wrong base backup. `conn_require_auth`
(libpq `require_auth`, PostgreSQL 16+) closes that for remote connections; local socket connections (peer) are
not affected. Default empty for test setups, required by the production checklist. A server that fails it gives
an authentication error: the probe classifies it as "server error" (never proof), and a standby that cannot
stream because of it is stopped by rule 1.

### 9.4 Lab results (1.8.2)

Same lab as 8.5 (two knet rings, `fence_virsh`, token 3000 ms), `conn_require_auth=scram-sha-256`,
`replication_failure_threshold=5`, standby monitor every 10 s:

| Scenario | Result |
|---|---|
| Primary serves the standby without authentication (`trust` in `pg_hba` for it) | standby refuses ("server did not complete authentication"), fails its monitor after 5 cycles, stopped; primary records it and relaxes: write gap 60.9 s, 0 lost |
| Primary fenced while the standby is recorded | standby stays Unpromoted at -INFINITY; the primary comes back and is promoted again |
| `pg_hba` repaired, cleanup | standby streams, record removed after the catch-up |
| Standby frozen, fencing | record set by the primary before relaxing, write gap 12.4 s, removed after the rejoin, 0 lost |
| Primary frozen 40 s, fencing | the promote records the old primary, write gap 18.0 s, removed after its rejoin, 0 lost |
| Standby powered off, no fencing | record, relax after the 6 s window: write gap 16.6 s, 0 lost |
| Standby back after its WAL was recycled on the primary (slot dropped) | starts, cannot stream; monitor sees the removed WAL, fails after 5 cycles, stopped; start rebuilds with `pg_basebackup`, streaming sync, record removed |
| `test-pgtwin-ha-suite.sh` | 12/12 (first run 8/12: switchover right after a rejoin refused, see rule 4) |
| `conn_require_auth` changed with `crm resource param` | standby: reload-agent; primary: restart (Pacemaker restarts a promoted instance on any parameter change, 16-18 s write stop); with maintenance mode + `crm_resource --refresh`: nothing restarted, 0.4 s |


### 9.5 A node that starts alone

A node whose peer is not a cluster member cannot compare data states. It
may be promoted only if nobody can have written after it (`promotion_alone_blocked`, `rep_mode=sync` only):

1. It was **primary/async** when it went down: it ran without waiting for its standby, and since 9.2 rule 2 that
   means the standby is recorded, so the standby was no candidate after it. Running primary: empty
   `synchronous_standby_names` (start path). Demoted at a shutdown with the peer not streaming and recorded:
   `.pgtwin_last_primary_async` (written before anything in the demote can fail, removed by a promote and by
   streaming as a member).
2. Or it has been a healthy, unrecorded standby of the peer **as a cluster member** since it booted
   (`$HA_RSCTMP/pgtwin-<rsc>.streamed`, gone after a reboot). That is an ordinary failover, 9.2 applies.
   Streaming without the peer as member does not count: dmkif's finding E blocked only corosync, the rebooted
   standby streamed asynchronously from a primary whose record it could not see.

Anything else (standby, or primary/sync when it went down) is not eligible: a standby at -INFINITY, promote
refuses. A former primary/sync that starts alone starts as such a standby (before: `OCF_ERR_CONFIGURED`, which
blocked the peer's start as well). Once the peer is a member, the data-state comparison decides. If the
primary/async node never returns: operator override `pgtwin-promote-alone-<rsc>` (transient).

Startup fencing (`no-quorum-policy=ignore`, the pgtwin default) is Pacemaker's; the rule only makes sure that a
node fenced and rebooted during a partition does not promote itself with older data.

### 9.6 No fence device can confirm

Fencing first; two primaries are the last thing to happen. When no fence device can confirm (host of the node
dead behind hypervisor fencing, full partition), Pacemaker waits for `stonith_admin --confirm`. A dead node and a
fully partitioned one look the same from here, so the decision is "this node is alone":

- `fence_pgtwin`, last level of `fencing_topology`: confirms if the target is not a member, and none of its
  addresses (corosync rings plus `extra_addresses`) answers `ping_count` pings after `delay`. Any answer: the
  target is alive, not confirmed (operator). With `gateway_attribute`: never confirms while this node's gateway
  attribute is 0.
- `isolation_action=demote` (default `none`): primary alone with gateway attribute 0 for `isolation_threshold`
  monitor runs: score -INFINITY, Pacemaker demotes it; a standby in that state is not a candidate; the no-fencing
  relax rule (1a) does not relax there. A missing attribute is "unknown", never "lost".

With both, a primary cut off from its gateway never relaxes (no confirmation), acknowledges nothing and steps
down; the side with the gateway confirms and promotes. If both sides keep a gateway, both become primary; when
they meet, rule 2 (newer timeline wins) keeps the node promoted last and the other is rewound, losing what it
acknowledged in between: the accepted last resort. Two data centres whose services should go on on each side
need a gateway per side (redundant gateway); a single gateway in one data centre makes the other side "cut off".

SBD as an extra level adds information only where its disk survives what the node dies of; in a two data centre
setup it sits in one of them. A QDevice in a third place helps some partitions, but not one that also cuts it off.

### 9.7 Divergence after a demote while alone

A primary demoted while it cannot reach the new primary has WAL on the old timeline after the switch point
(commits that waited for the standby, the shutdown checkpoint). Its walreceiver later fetches the new history
file; `local_effective_timeline` took any newer history file as "follows that timeline" (1.8.1, against false
divergences of crashed standbys, whose minimum recovery point is already on the new timeline). Now a history
file counts only if the node's position on its checkpoint timeline (checkpoint or minimum recovery point) is not
past that file's switch point for it; otherwise the start sees the divergence and runs `pg_rewind`.

### 9.8 Lab results (sections 9.5-9.7)

Same lab, `fence-alone` (`fence_pgtwin`, `delay=5 ping_count=5 ping_interval=2 gateway_attribute=pingd`) as
level 2 after `fence-virsh`, ping resource on the hypervisor host (192.168.122.1):

| Scenario | Result |
|---|---|
| Finding E: both rings blocked on the primary, PostgreSQL reachable, `no-quorum-policy=ignore` | primary fences the standby, relaxes; rebooted standby: "alone", stays standby, fences the primary; primary back, comparison promotes it; 179 acknowledged, 0 lost |
| `fence-virsh` unreachable from the primary, standby destroyed | `fence_pgtwin` confirms after 15 s, primary records and relaxes: write gap 25 s, 0 lost |
| Full partition (all traffic, VIP, hypervisor fence), gateway on both | both confirm, both primary; heal: old primary steps down (rule 2), rewound; its 240 commits acknowledged after relaxing are lost (expected) |
| Same, primary loses the gateway, `isolation_action=demote` | cut-off primary never confirms or relaxes, demotes after 3 runs; other side primary after 25 s; heal: divergence detected (9.7), rewound; 0 lost |
| Same before the 9.7 fix | old primary not rewound, could never stream, stopped for good |

### 9.9 Cold start ranking

Both nodes standbys, no primary: `cold_start_eligibility` (end of the start, and every monitor in the "no primary
exists" branch) compares timeline and LSN with the peer once the peer answers as a standby. Newer: score base +
5000 (above location and ping rules, below the promoted bonus); older: -INFINITY; equal: base (the scheduler's
choice, either loses nothing). `promotion_data_state_guard` at promote time stays the safety net. Lab: preferred
node unable to catch up, the other newer: promoted directly, no failed action (dmkif T5 had a failed promote).
