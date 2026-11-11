# pgtwin v1.8.1 Release Notes

**Release date:** 2026-11-11
**Type:** bug fix release, upgrade recommended for everyone on 1.8.0

## Overview

dmkif ran the full test matrix on 1.8.0 in two labs (SBD; two corosync rings without fencing) and found five
problems, two of them in the new stall logic. Data on a primary is never corrupted, but:

| # | Problem in 1.8.0 | Impact |
|---|---|---|
| 1 | A standby that crashed shortly after a timeline switch could become unrecoverable | no standby until a manual basebackup |
| 2 | Both cluster rings down without fencing: relaxed while the peer was being promoted | **acknowledged commits lost** (4 in one run) |
| 3 | With fencing, a fenced or frozen standby kept writes blocked until it came back | write stop 199 s, unbounded if the standby never returns |
| 4 | Upgrade from 1.7.x: the primary could lose its promotion score for a moment | demoted, 93 s without primary |
| 5 | The standby streamed from the VIP | every switchover 60 s slower (69-77 s) |

All five are fixed and tested, see below. On the way the promotion safety check was fixed: it could not read the
standby's sync state on a reachable primary (see 6).

## 1. Crashed standby after a timeline switch

1. After a timeline switch the standby's control file keeps the old timeline as "Latest checkpoint's TimeLineID"
   until its first restartpoint (up to `checkpoint_timeout`, 5 min by default).
2. If the standby crashed in that window, the start path compared that value with the primary's timeline, saw a
   "divergence" and ran `pg_rewind` (this check exists since 1.6.12; before 1.8.0 the rewind failed and a full
   basebackup followed).
3. `pg_rewind` finishes the crash recovery of an uncleanly stopped target in single-user mode. 1.8.0 moves
   `standby.signal` aside for that (needed for crashed primaries). For a standby this crash recovery replays up to
   the minimum recovery point, which is already on the new timeline, and then **ends recovery**: it writes an
   end-of-recovery checkpoint on the primary's timeline at the end of the WAL the standby had received. If the last
   record was only partially received, that checkpoint sits at a position where the primary has a different record.
4. `pg_rewind` then finds both on the same timeline ("no rewind required") and reports success. The standby fails
   at that LSN on every start or retry (`record with incorrect prev-link`, `invalid resource manager ID`,
   `invalid record length`), and Pacemaker ends at fail-count INFINITY.

1.8.1:
- **No false divergence**: for a node in recovery the start path uses the timeline the standby follows (the newest
  of the checkpoint timeline, the minimum recovery point's timeline and the history files it received).
- **No `pg_rewind` on a crashed standby** (`in archive recovery`): rebuilt with `pg_basebackup` if a divergence is
  reported. The signal files are moved aside only for a crashed primary, where the rejoin via `pg_rewind` stays.
- **Repair of standbys already in that state**: the monitor rebuilds a standby that cannot stream when `pg_rewind`
  reports "no rewind required"; a standby start that fails with the same WAL read error at the same LSN three
  times falls back to `pg_basebackup`.

## 2. No relax while the peer may be promoting (no fencing)

Without fencing Pacemaker sends no stop notification for a lost node, so the primary monitor may relax
`synchronous_standby_names` itself when the peer is offline in the cluster and its PostgreSQL does not answer
(rule 1a, `doc/DESIGN_STALL_SAFE_SYNC.md`). 1.8.0 took a single failed probe as "does not answer". In dmkif's run
with both rings down the probe hit the peer during its promotion, the primary acknowledged four more commits
asynchronously, and they were gone after the peer won.

1.8.1:
- The probe result is classified: answers (`t`/`f`), server error (authentication, startup, ...: the host is
  alive) or unreachable (refused, timeout, no route). Only "unreachable" counts.
- The monitor relaxes only after the peer has been unreachable without a break for **6 s over at least two
  probes**. Any answer resets the window; a peer that answers as primary on a newer timeline makes this node step
  down (rule 2), as before.
- The peer is probed once per monitor run (rule 1a and rule 2 share the result), so the window costs about 6 s,
  not two connect timeouts per cycle.

Cost: without fencing, the write stop after a standby failure grows by the window (lab: 18.6 s instead of about
12 s). With fencing nothing changes.

## 3. Relax after a confirmed fence (fencing)

With fencing the post-stop notification Pacemaker sends after the confirmed fence relaxes. 1.8.0 did that only
with an empty `pg_stat_replication`, but the walsender of a fenced or frozen standby stays listed until
`wal_sender_timeout`. Afterwards nothing relaxed any more: writes stayed blocked until the standby came back.

1.8.1:
- The post-stop notification ends the walsender of the stopped peer and relaxes; it logs its decision in every
  case.
- Fallback in the monitor: the cluster has recorded the peer as **offline and clean** (fenced or stopped, not just
  lost). This is the cluster's result, not an own observation; raw fence events are not used.

## 4. Upgrade from 1.7.x without losing the promotion score

1.8 keeps the promotion score as a transient attribute and removes the permanent one of earlier versions. 1.8.0
removed the permanent value first; when the scheduler ran before the transient value reached the CIB, the
primary had no score and was demoted. 1.8.1 sets the transient value first and removes the permanent one once
the transient value is visible in the CIB.

## 5. The standby streams from the node, not from the VIP

1.8.0 fixed the authentication of the discovery queries, so discovery via the VIP succeeds and the standby's
`primary_conninfo` pointed at the VIP. At a demote the VIP is stopped first, the standby's connection hangs
without a reset, and the old primary's shutdown waits for its walsender until `wal_sender_timeout`. 1.8.1 returns
the node behind the VIP (the peer whose `pg_postmaster_start_time()` matches), and the monitor moves a standby that
streams from the VIP to that node (reload, the walreceiver reconnects; no restart).

## 6. Promotion safety check on a reachable primary

Before a promotion the standby checks that it is `sync` on the primary, if the primary still answers (e.g. only
the cluster network is down). The query ran as the postgres role without a password, and the replication user
needs `pg_read_all_stats` to see `sync_state`. In setups following QUICKSTART the check therefore blocked the
promotion whenever the old primary answered. It now queries as the replication user and logs the missing grant
explicitly.

## Upgrade notes

- **Grant `pg_read_all_stats` to the replication user** (QUICKSTART.md 1.6):
  `GRANT pg_read_all_stats TO replicator;`. Without it the promotion is blocked while the old primary answers (as
  before, but now with a clear log message).
- Replace the agent with a copy and rename (`cp pgtwin pgtwin.new && mv pgtwin.new pgtwin`), not by overwriting it
  in place: bash reads a running script incrementally, an operation in progress then fails with syntax errors and
  `OCF_ERR_CONFIGURED`, which stops the resource on all nodes. RPM updates rename and are not affected.
- A standby stuck in the state of problem 1: `crm resource cleanup` after the upgrade lets 1.8.1 rebuild it.
- Standbys streaming from the VIP are moved to the primary's node by their next monitor.
- **Downgrade to 1.7.x**, on every node in this order: `crm_attribute -N <node> -n master-<rsc> -l forever -v 10`,
  then `crm_attribute -N <node> -n master-<rsc> -l reboot -D`. Deleting only the transient value leaves a 1.7.13
  primary without a score (it does not write the permanent value itself), and it is demoted.
- Timing: the stall handling relies on Pacemaker's decisions, so failure handling is detection time (corosync
  token + consensus) plus fence time plus promote. With two corosync rings a token of 3000 ms is reasonable;
  power or hypervisor fencing (IPMI, `fence_pve`, `fence_virsh`, ...) confirms "off" within seconds, SBD has to
  wait for `msgwait`.

## Tests

Lab: two KVM nodes (openSUSE Tumbleweed, PostgreSQL 17.11, Pacemaker 3.0.3), `rep_mode=sync`. Problem 1 with SBD
and a single ring; problems 2-6 with two knet rings, `fence_virsh` power fencing via the hypervisor, token 3000 ms
and no SBD (fencing disabled for the no-fencing cases). Writer over the VIP from the surviving node, every
acknowledged id checked on the final primary.

| Test | 1.8.0 | 1.8.1 |
|---|---|---|
| Standby powered off after a switchover, min. recovery point on the new timeline | false divergence, `pg_rewind` "success", every start fails, fail-count INFINITY | crash recovery as standby, streaming sync, 578 acknowledged ids present |
| Standby in that broken state (made by hand) | monitor repeats no-op `pg_rewind` | detected, `pg_basebackup`, sync after 45 s |
| Primary powered off (real divergence) | rejoin via `pg_rewind` | unchanged |
| Both rings down, no fencing, peer promotes | dmkif: 4 acknowledged lost | primary does not relax, steps down 1 s after the peer's promotion, 0 lost |
| Same, primary's probes blocked for 5 s during the peer's promotion (race of problem 2) | (relax on the first failed probe) | "unreachable, waiting", then step down, 0 lost |
| Standby powered off, no fencing | relax after one failed probe | relax after 6 s: write gap 18.6 s, 0 lost |
| Standby frozen, fencing | dmkif: writes blocked 199 s (until the resume) | fenced after 4 s, relaxed 2 s later: write gap 12.8 s, 0 lost |
| Primary frozen 40 s, fencing | - | takeover, write gap 22.4 s (detection 6.5 s, fence incl. 5 s priority delay 8.3 s, promote 5 s), 0 lost |
| Both rings down, fencing | - | primary fences the standby first, write gap 3.2 s, 0 lost |
| Primary with only the permanent score (state after the upgrade), 5 runs | dmkif: demoted in 2 of 4 upgrades | permanent value removed after the transient one, no scheduler action |
| Standby streaming from the VIP | - | moved to the node by the next monitor within 3 s |
| Switchover (`crm node standby <primary>`) with VIP discovery | dmkif: 69-77 s | 20 s, 0 lost |
| Unit tests (`test-promotion-data-state.sh`, `test-cold-start-eligible.sh`, `test-safe-sync-names.sh`) | - | all pass |
| `test-pgtwin-ha-suite.sh` | - | 12/12 (dual rings, power fencing) |
