# pgtwin v1.8.2 Release Notes

**Release date:** 2026-11-12
**Type:** behaviour changes in the stall and partition handling, optional security and partition parameters, a new fence agent; upgrade recommended

## Overview

| # | Change | Why |
|---|---|---|
| 1 | A standby that runs but cannot stream is stopped by Pacemaker | writes stayed blocked when the repair inside the monitor did not help (authentication, `pg_hba`) |
| 2 | Before relaxing, the primary records the standby as "not in sync"; such a node is never promoted automatically | a standby that was back but not caught up could be promoted after a failure of the primary and lose acknowledged commits |
| 3 | New parameter `conn_require_auth` (libpq `require_auth`) | libpq accepted a server that skips authentication: whoever answered on a node address or the VIP could pose as primary or standby |
| 4 | A node that starts alone is promoted only if it was primary/async | dmkif (finding E): a fenced standby that booted during a partition fenced the healthy primary and promoted itself |
| 5 | New fence agent `fence_pgtwin` (last level) and parameter `isolation_action` | when no fence device can confirm (dead host, full partition) nothing failed over until someone confirmed by hand |
| 6 | Divergence of a former primary demoted while alone is detected | it fetched the new primary's history file and took it for "following", so the start never rewound it |
| 7 | Cold start: the node with the newer data is promoted directly | dmkif T5: Pacemaker promoted by location, the data-state guard refused, a failed promote action remained |

Design: `doc/DESIGN_STALL_SAFE_SYNC.md`, section 9.

## 1. A sick standby is stopped, not tolerated

dmkif asked to relax synchronous replication when a standby runs but does not stream for longer than the promote
timeout. 1.8.2 does not do that: a running standby that does not integrate is a promotion candidate whose data
is behind, and relaxing next to it leaves every later event to chance. Instead the cluster turns it into a
stopped standby, and the primary relaxes on the stop notification as before:

- After `replication_failure_threshold` (default 5) consecutive monitor cycles without streaming, and only while
  a Promoted peer is an online member, the standby monitor fails the instance ("Standby cannot stream from the
  primary on ... for 5 monitor cycles").
- Pacemaker stops it (and fences the node if the stop fails). The primary ends its walsender and relaxes on the
  post-stop notification.
- The next start repairs what it can: `pg_rewind` on a timeline divergence, `pg_basebackup` when the WAL is
  removed on the primary (the monitor checks that before failing) or recovery fails at the same WAL position.
- A standby that cannot be repaired (authentication, `pg_hba`) fails again and is banned after
  `migration-threshold` failures: a stopped standby, a failed action with a reason, writes asynchronous.

Before, the monitor ran the repair itself and returned success. No stop notification came, so the primary kept
waiting as long as the repair did not help.

Write stop until the relax: about (threshold + 1) x the Unpromoted monitor interval (lab, 5 x 10 s: 60.9 s). The
threshold is deliberately generous: it is the time a standby gets to set up, recover or catch up before it is
stopped. Reads and the failover of a lost primary do not depend on it.

## 2. "Not in sync" record

Before a primary with `rep_mode=sync` stops waiting for its standby (post-stop notification, monitor, promote)
it writes the permanent node attribute `pgtwin-unsynced-<resource>` on that node and waits until it is in the
CIB; if it cannot be written, the primary keeps waiting. From then on the primary may acknowledge commits the
standby lacks, so:

- the node's promotion score stays -INFINITY, also when no primary is left, and promote refuses;
- the primary removes the record once the node streams as synchronous standby and has flushed past the position
  where waiting resumed (usually in the same monitor run, seconds after a rejoin), and on a clean demote when the
  node streamed from it and has received past its shutdown checkpoint (a switchover right after a rejoin works);
- if the primary is lost for good while the record exists, there is no automatic failover. The operator decides
  whether the commits since the recorded time may be lost and removes the record
  (`crm_attribute -N <node> -n pgtwin-unsynced-<resource> -l forever -D`), QUICKSTART "A standby recorded as not
  in sync".

This closes the double failure "standby fenced, back and streaming but not caught up, primary fails, standby
promoted", which earlier versions had as well.

## 3. `conn_require_auth`

```
crm resource param postgres-db set conn_require_auth scram-sha-256
```

Adds `require_auth` to every connection the agent makes to another node: probes, discovery, the promotion
safety check, `primary_conninfo`, `pg_rewind` and `pg_basebackup`. Local socket connections (peer) are not
affected. A server that does not authenticate is refused with an authentication error; the probe treats that as
"server error" (never as proof), and a standby that cannot stream because of it is stopped as in section 1.

- Default empty: same behaviour as before, convenient for test setups. The production checklist in QUICKSTART
  requires it, together with `pg_hba` entries for the replication user only from the node addresses.
- Needs a PostgreSQL 16+ client (validated at start).
- Reloadable: the standby takes it with a `reload-agent` and switches its `primary_conninfo` with its next
  monitor. Pacemaker restarts a **promoted** instance on any parameter change, though (lab: 16-18 s write
  stop, no failover). QUICKSTART describes how to change it without that restart (maintenance mode and
  `crm_resource --refresh`).

## 4. A node that starts alone

dmkif's finding E (lab 2, `no-quorum-policy=ignore`, the pgtwin default): both rings down, the primary fences the
standby and relaxes; the standby boots while the partition lasts, fences the healthy primary (startup fencing)
and promotes itself. In a real full partition the commits the primary acknowledged after relaxing are lost, and
the nodes keep fencing each other.

With `rep_mode=sync` a node whose peer is not a cluster member can no longer compare data states. 1.8.2 promotes
it only if nobody can have written after it:

- it was **primary/async** when it went down: running without waiting for its standby, with the standby recorded
  as not in sync (section 2), so the standby was no candidate after it. A running primary: empty
  `synchronous_standby_names`; demoted at a shutdown: a marker file (`.pgtwin_last_primary_async`).
- or it has been a healthy, unrecorded standby of the peer since it booted, **both cluster members** (an ordinary
  failover; the record rules apply). Streaming from a peer that is not a member (dmkif's partition blocked only
  corosync) does not count.

Any other state is not eligible: the node starts as standby and logs "This node is alone ...". Once the peer
joins, the data-state comparison picks the node with the newer data. If the node that was primary/async does not
come back, the operator decides: `crm_attribute -N <node> -n pgtwin-promote-alone-<resource> -l reboot -v true`.

A former primary that starts alone while it was waiting for its standby now starts as such a standby. Before it
failed with `OCF_ERR_CONFIGURED`, which stopped the resource cluster-wide, so the peer did not start either when it
came back.

Pacemaker's startup fencing itself is unchanged: in finding E both nodes are still fenced once. Lab (both rings
blocked on the primary, PostgreSQL reachable, fencing, `no-quorum-policy=ignore`): the rebooted standby stayed
standby ("alone"), fenced the primary; the primary came back, the comparison promoted it; 179 acknowledged, 0 lost.

## 5. When no fence device can confirm: `fence_pgtwin` and `isolation_action`

As long as any fence device can reach the other node, it is used and two primaries never happen. When none can
confirm, Pacemaker waits; dmkif's lab 2 (hypervisor fencing only, host of the node dead) had no failover for
378 s. pgtwin cannot tell a dead node from a fully partitioned one, so the decision is "this node is alone":

- **`fence_pgtwin`** (new, `/usr/sbin/fence_pgtwin`), only as the **last** fencing level: confirms the fence
  when the target is not a cluster member and none of its addresses (corosync ring addresses plus
  `extra_addresses`) answers 5 consecutive pings (after a 5 s delay; adds 15 s). Any answer: the target is
  alive, not confirmed. With `gateway_attribute=pingd` a node that has lost its gateway never confirms.
- **`isolation_action=demote`** (new pgtwin parameter, default `none`): a primary that is alone and has lost its
  gateway (ping resource attribute 0) gives up the primary role after `isolation_threshold` (3) monitor runs; a
  standby in that state is not promoted; the no-fencing relax rule does not relax there.

In a full partition where both sides reach a gateway both become primary; when they meet the node promoted last
stays, the other is rewound and loses the commits it acknowledged in between. That is the accepted last resort.
**Two data centres in which the services should go on on each side need a redundant gateway setup** (a gateway
per side in the ping resource's `host_list`); with a single gateway in one data centre the other side counts as
cut off.

A demote while alone (no primary to follow) now points the standby at the peer's address instead of failing.

SBD as a second level helps only where its disk survives what the node dies of; in a two data centre setup it
sits in one of them and adds no information. The 1.8.1 release notes' advice stands: power or hypervisor fencing
first.

## 6. Divergence of a former primary demoted while alone

A former primary that is demoted while it cannot reach the new primary writes WAL on the old timeline after the
switch point (commits that waited for the standby, the shutdown checkpoint). Its walreceiver later fetches the
new primary's history file, and `local_effective_timeline` (1.8.1, against false divergences of crashed
standbys) took that file as "this node follows the new timeline". The start found no divergence, ran no
`pg_rewind`, and the standby could never stream (lab: stopped for good after the sick-standby stop). A history
file now counts only if the node's position on its checkpoint timeline is not past the switch point in that file.

## 7. Cold start: newer data first

dmkif's T5: both nodes start as standbys, no primary; Pacemaker promoted the node with the location preference,
the data-state guard found the peer newer (`145/0/48016E20` vs `145/0/48016E98`) and refused, and a failed
promote with fail-count 1 remained before the peer was promoted.

Now each standby compares timeline and WAL position with the peer as soon as both answer (end of the start and
every monitor while no primary exists): the newer one gets a score above location and ping preferences, the
older one -INFINITY, equal states the normal score (either node loses nothing, the scheduler's choice). The
guard at promote time stays the safety net for anything that changes in between. If there was a conflict, a
person decides; QUICKSTART "Choosing the primary by hand" lists every block and its override.

## Upgrade notes

- Replace the agent with copy + rename as for 1.8.1 (`cp pgtwin pgtwin.new && mv pgtwin.new pgtwin`), also
  `pgtwin-container-lib.sh` in container mode. Copy `fence_pgtwin` to `/usr/sbin` (mode 755, `restorecon` with
  SELinux) on every node, also if you do not configure it yet.
- Nothing to configure. `fence_pgtwin` and `isolation_action` are opt-in (QUICKSTART "When no fence device can
  confirm"). After the upgrade a primary that runs asynchronously records its standby with its next
  monitor; the record is removed as soon as the standby is in sync.
- Monitoring: alert on `pgtwin-unsynced-<resource>` in `crm_mon -A` and on failed standby monitors.
- Downgrade: remove the records first (`crm_attribute -N <node> -n pgtwin-unsynced-<resource> -l forever -D` on
  every node); 1.8.1 does not know them.

## Tests

Lab: two KVM nodes (openSUSE Tumbleweed, PostgreSQL 17.11, Pacemaker 3.0.3), two knet rings, `fence_virsh`,
token 3000 ms, `rep_mode=sync`, `conn_require_auth=scram-sha-256`, standby monitor 10 s. Writer over the VIP
from the surviving node, every acknowledged id checked on the final primary.

| Test | Result |
|---|---|
| Primary serves the standby without authentication (`trust` for it in `pg_hba`) | standby refuses, fails its monitor after 5 cycles, stopped; primary records it, relaxes: write gap 60.9 s, 0 lost |
| Primary fenced while the standby is recorded | standby stays Unpromoted (-INFINITY); primary back and promoted again |
| `pg_hba` repaired, cleanup | standby streams in sync, record removed |
| Standby frozen, fencing | recorded, write gap 12.4 s (1.8.1: 12.8 s), record removed after the rejoin, 0 lost |
| Primary frozen 40 s, fencing | promote records the old primary, write gap 18.0 s (1.8.1: 20.3 s), removed after the rejoin, 0 lost |
| Standby powered off, no fencing | recorded, relax after the 6 s window: write gap 16.6 s (1.8.1: 18.6 s), 0 lost |
| `conn_require_auth` set/removed with `crm resource param` | standby `reload-agent`, primary restarted (16-18 s) |
| Same with maintenance mode + `crm_resource --refresh` | nothing restarted, write gap 0.4 s |
| Standby back after its WAL was recycled on the primary (slot dropped) | starts, cannot stream; monitor sees the removed WAL, fails after 5 cycles, stopped; start rebuilds with `pg_basebackup`, streaming sync, record removed |
| Switchover seconds after a standby rejoin (HA suite) | first run: target still recorded, promotion refused, no primary; fixed (record cleared in the same monitor run and on a clean demote) |
| Finding E: both rings blocked on the primary, PostgreSQL reachable, fencing, `no-quorum-policy=ignore` | primary fences the standby, relaxes; rebooted standby stays standby ("alone"), fences the primary; primary back, data-state comparison promotes it; 179 acknowledged, 0 lost |
| Hypervisor fence unreachable, standby really dead (`fence_pgtwin` last level) | `fence_virsh` fails, `fence_pgtwin` confirms after 15 s, primary records and relaxes: write gap 25 s, 0 lost |
| Full partition (all traffic, VIP and hypervisor fence blocked), gateway on both sides | both confirm, both primary; after the heal the old primary steps down (newer timeline on the peer) and is rewound; the 240 commits it acknowledged after relaxing are lost (expected, section 5) |
| Same, primary also loses the gateway, `isolation_action=demote` | the cut-off primary never confirms, never relaxes, demotes after 3 runs; the other side is primary after 25 s; after the heal the old primary is detected as diverged and rewound; 0 acknowledged commits lost (3 runs) |
| First run of that test | the old primary fetched the new history file and was not rewound, stopped for good: fixed (section 6) |
| T5: cold start, the node with the location preference cannot catch up, the other has newer data | "Cold start: pg2 has the newer data state" on pg1 (-INFINITY), pg2 preferred and promoted directly, no failed action; both nodes' rows present |
| Same with both able to stream | the standbys catch up from each other (cascading), equal states, the preferred node promoted |
| Unit tests (`test-promote-alone.sh`, `test-isolation.sh`, `test-effective-timeline.sh`, `test-cold-start-rank.sh` new; the 1.8.1 ones) | all pass |
| `test-pgtwin-ha-suite.sh` | 12/12 (with sections 4-6, `fence-alone` configured as level 2) |
