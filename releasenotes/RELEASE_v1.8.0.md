# pgtwin v1.8.0 Release Notes

**Release Date:** 2026-11-10
**Type:** Minor release (fixes and changed defaults, no removed interface)
**Status:** Tested on a two-node lab, see "Tests"

---

## Overview

This release makes failovers fast and predictable and closes several paths that ended in a full `pg_basebackup`
or in no primary at all. It includes the unreleased 1.7.12 and 1.7.13 from `dmkif/pgtwin`.

| Scenario | 1.7.11 | 1.8.0 |
|---|---|---|
| Planned switchover (`crm node standby`, `crm resource move`) | 49-104 s, `move` to one direction impossible | 19-30 s |
| Clean shutdown of the primary's node | - | 22 s |
| Primary PostgreSQL dies, restart fails | no failover in one direction (> 180 s) | 42-45 s |
| Hard crash of the primary's node, SBD | - | 114 s, of which ~9 s pgtwin (rest: fencing delays, see below) |
| Rejoin of a crashed old primary | full `pg_basebackup` | `pg_rewind`, ~8 s |
| Rejoin after a long absence with WAL churn | `pg_basebackup` (WAL recycled) | `pg_rewind` (slot prepared before promotion) |
| Primary stalls (paused VM) while the standby is promoted | old primary switches to async, acknowledges commits that are discarded; the scheduler may demote the new primary | old primary acknowledges nothing, steps down; the promoted node survives |

No acknowledged commit was lost in any of the tests.

---

## Upgrade notes

- **`promotion_peer_wait` defaults to 30 s** (was 60 s); the hard limit is 40 s (was 100 s). Both are measured from
  the start of the check. Set the parameter explicitly if you relied on the longer wait.
- **Equal data states no longer use a tie-break by node name**: the node Pacemaker chose is promoted.
- **`resource-stickiness`**: set `rsc_defaults resource-stickiness=50` (QUICKSTART section 2.11). With 100 a primary
  that lost its connectivity keeps the Promoted role. Check your values with `crm_simulate -sL`.
- **Standby slot**: the standby now keeps a physical slot named `slot_name` at the REDO point of its last
  restartpoint. It holds back about one checkpoint interval of WAL on the standby.
- **Discovery** now authenticates as the replication user on database `postgres`; the `.pgpass` entries from
  QUICKSTART section 1.9 are required (they always were documented).
- Install the updated `pgtwin-container-lib.sh` as well (connect timeout in container mode).
- **Promotion score**: `master-<rsc>` is now a transient attribute (was a permanent 10, which the agent removes).
  In steady state it is 10 as before; right after a promotion it is 10000 above the peer's until a standby is in
  sync again. While the bonus is active (between a failover and the resync) no connectivity failover happens.
- **Synchronous replication is relaxed only by promote and the standby's stop** (and, without fencing, when the
  standby is offline and does not answer). With fencing, writes block until the standby is fenced; a standby that
  runs but does not stream keeps writes blocked until its own recovery stops it. See
  `doc/DESIGN_STALL_SAFE_SYNC.md` section 8.
- **Downgrade to 1.7.x**: the transient value of 1.8 shadows the permanent `master-<rsc>` attribute until the node
  reboots (also a bonus of 10000 or `-INFINITY`), and a 1.7.13 primary does not write the permanent value itself.
  On every node, in this order: first `crm_attribute -N <node> -n master-<rsc> -l forever -v 10`, then
  `crm_attribute -N <node> -n master-<rsc> -l reboot -D`. Deleting only the transient value leaves the primary
  without a score and it is demoted (corrected after dmkif's rollback test).
- **Upgrade to 1.8.1**: 1.8.0 can leave a standby that crashed shortly after a timeline switch unrecoverable (see
  `RELEASE_v1.8.1.md`).

---

## What's fixed

1. **Switchover delays.** No libpq connection had a connect timeout. During a switchover the VIP is down and a
   discovery query hung in TCP SYN retries (39-72 s in one call, found with `crm resource trace`). The agent
   exports `PGCONNECT_TIMEOUT` (5 s; 2 s for discovery) and checks a leaving peer before any query.
2. **Discovery never worked** in a QUICKSTART setup (queries as the `postgres` role without password); only the CIB
   fallback did.
3. **`crm resource move`** to the node with the larger name was refused (tie-break) and a standby on the new timeline
   was judged older (checkpoint timeline lags). Both fixed.
4. **False `pg_rewind` on every switchover** against the not yet promoted standby.
5. **`pg_rewind` after a crash** failed in single-user mode because of `standby.signal`; a basebackup ran instead.
6. **Slot created too late**: after the promotion the post-promotion checkpoint completed first. The standby now
   prepares the slot.
7. **Consistent standby with WAL gone** looped on pg_rewind in the monitor; it is now rebuilt.
8. **No failover when the primary's restart failed**: the standby vetoed its own promotion. It stays eligible when
   no primary exists (peer is a standby, or silent while the CIB shows no promoted instance).
9. **Auto-initialization loop** with only pgtwin-written files in PGDATA.
10. Hyphenated node names in `synchronous_standby_names` (dmkif, 1.7.12); cold-start eligibility (dmkif, 1.7.13).
11. The pre-basebackup version check never ran (`PG_CTL` vs `PGCTL`).
12. **Stall of the primary**: the old primary relaxed to async on its own stale view and acknowledged commits;
    after the reconcile the scheduler demoted the node with the lower score, which could be the new primary. Now the
    monitor and start only tighten, the score carries the timeline, a stale primary steps down and never restarts
    as a second primary (`doc/DESIGN_STALL_SAFE_SYNC.md`).

---

## Failover time after a hard crash

Measured with the defaults `crm cluster init` sets (power-off of the primary):

| Phase | Time |
|---|---|
| Corosync declares the node lost (token 5 s + consensus 6 s) | 11 s |
| `priority-fencing-delay=60` + random `pcmk_delay_max` (0-30 s) | 64 s |
| SBD `msgwait` | 30 s |
| pgtwin promote | ~9 s |

The fencing delays protect against both nodes fencing each other in a split brain. With `priority-fencing-delay=15`
and `pcmk_delay_max=0` the total is about 65 s, with an additional SBD `msgwait` of 10 s about 45 s. IPMI/BMC or
hypervisor fencing takes seconds. Decide the trade-off for your environment; dual rings do not replace fencing
(`doc/DESIGN_STALL_SAFE_SYNC.md`).

---

## Tests

Lab: two KVM nodes (openSUSE Tumbleweed, PostgreSQL 17.11, Pacemaker 3.0.3, crmsh 5.1), SBD with iTCO watchdog,
`rep_mode=sync`, VIP and ping resource as in QUICKSTART.md.

| Test | Result |
|---|---|
| Unit tests: `test-promotion-data-state.sh` (28), `test-cold-start-eligible.sh` (8), `test-safe-sync-names.sh` (5), WAL log-scan (7) | all pass |
| `test-pgtwin-ha-suite.sh` (12 tests) | 12/12 |
| 6 switchovers via `crm node standby`, 4 via `crm resource move` | 19-30 s, rejoin via `pg_rewind` or streaming, no basebackup |
| Slot dropped on the primary while the standby is stopped | recreated before the standby starts, streams sync |
| Standby away, slot dropped, WAL recycled | monitor detects the missing WAL and rebuilds via `pg_basebackup` |
| Old primary away, heavy WAL churn on the new primary | 0 WAL files removed (slot from before the promotion), rejoin via `pg_rewind` |
| Staggered shutdown, stale node is the preferred one and starts first | no acknowledged row lost |
| Primary PostgreSQL killed, restart blocked (both directions) | failover 42 s / 45 s, no row lost |
| Crashed old primary rejoins | `pg_rewind`, ~8 s |
| Hard crash (VM destroyed), SBD fencing, reboot | failover 114 s, no row lost, rejoin via `pg_rewind` |
| Clean poweroff of the primary's node | failover 22 s, no fencing, no row lost |
| `crm_simulate`, primary with `pingd=0` | stickiness 50: failover; 100: none |
| Stall of the primary 40 s (`virsh suspend`), no fencing, both directions | promoted node survives, old primary standby after 22-23 s, 0 acknowledged commits lost |
| Same, the promoted node has also lost its ping (location and connectivity favour the old primary) | promoted node survives the reconcile, then a normal connectivity switchover, 0 lost |
| Stall of the primary 130 s, SBD | old primary reset by SBD at the resume, 0 lost |
| Stall of the standby 45 s, no fencing | async after 17 s, sync again 9 s after the resume, 0 lost |
| Standby crash with SBD / without fencing | async after the fence (63 s) / 1 s after the standby is offline |

Not covered: real hardware timing, container mode on a live cluster, a full partition of both rings.
