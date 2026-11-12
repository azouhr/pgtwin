## [1.8.2] - 2026-11-12

Release notes: `releasenotes/RELEASE_v1.8.2.md`.

### Changed
- **A standby that runs but cannot stream is stopped, not tolerated** (doc/DESIGN_STALL_SAFE_SYNC.md, section 9;
  answer to dmkif's request to relax after the promote timeout). After `replication_failure_threshold`
  consecutive monitor cycles without streaming, and only while a Promoted peer is online, the standby monitor
  fails the instance. Pacemaker stops it (fences the node if the stop fails), the primary relaxes on the
  post-stop notification. Before, the monitor ran `pg_rewind`/`pg_basebackup` itself and returned success, so no
  stop notification came and writes stayed blocked when the repair did not help (authentication, `pg_hba`).
  Repair moved to the start; the removed-WAL check runs in the monitor before failing and asks the next start for
  a `pg_basebackup`.
- `replication_failure_threshold` description: the write stop after a standby failure is about
  (threshold + 1) x the Unpromoted monitor interval.

### Fixed
- **Divergence of a former primary that was demoted while alone** was not detected: its walreceiver fetched the
  new primary's history file later, and `local_effective_timeline` took that as "follows the new timeline", so
  the start ran no `pg_rewind` and the standby could never stream. A newer history file now counts only if the
  node's position on its checkpoint timeline is not past the switch point in that file.
- A demote while alone (no primary to follow) no longer fails with "Cannot determine primary host": the
  standby points at the peer's address.

### Added
- **Cold start: the node with the newer data is promoted directly** (dmkif T5). When both nodes are standbys and
  no primary exists, each compares timeline and WAL position with the peer as soon as both answer: newer gets a
  score above location and ping preferences, older -INFINITY, equal the normal score (the scheduler's choice).
  Before, Pacemaker promoted by location and the data-state guard refused the older node, which left a failed
  promote action. The guard stays as the safety net.
- QUICKSTART "Choosing the primary by hand": every safety block with the command that overrides it.
- **`fence_pgtwin`**, a fence agent for the last level of `fencing_topology`: when no real fence device can
  confirm, it states "this node is alone" if the target is not a cluster member and none of its addresses
  (corosync ring addresses plus `extra_addresses`) answers `ping_count` consecutive pings; optionally only while
  this node reaches its gateway (`gateway_attribute`). Installed to `/usr/sbin` by the spec.
- **`isolation_action`** (`none` default, `demote`), `gateway_attribute` (`pingd`), `isolation_threshold` (3):
  a primary that is alone and has lost its gateway gives up the primary role; a standby in that state is not
  promoted; the no-fencing relax rule does not relax there.
- **A node that starts alone is promoted only if it was primary/async** (`rep_mode=sync`; dmkif finding E: with
  `no-quorum-policy=ignore` a fenced standby that booted during a partition fenced the healthy primary and
  promoted itself). Without the peer as a cluster member a node is a promotion candidate only if it was primary
  without waiting for its standby when it went down (the standby recorded as not in sync), or if it has been a
  healthy, unrecorded standby of the peer as a cluster member since it booted. Otherwise it stays an ineligible
  standby until the peer joins and the data-state comparison decides; operator override
  `pgtwin-promote-alone-<rsc>`. A former primary that starts alone while it was waiting for its standby now
  starts as such a standby; before it failed with `OCF_ERR_CONFIGURED`, which also kept the peer from starting
  until a cleanup.
- **"Not in sync" record**: before a primary with `rep_mode=sync` stops waiting for its standby (post-stop,
  monitor rules 1a/1c, promote) it writes the permanent node attribute `pgtwin-unsynced-<rsc>` on the peer and
  waits until it is in the CIB; without it the primary keeps waiting. A recorded node is never promoted
  automatically (score -INFINITY, promote refuses), also when the primary is lost: it may miss acknowledged
  commits. The primary removes the record once the peer is its synchronous standby and has caught up, and on a
  clean demote once the peer has received its shutdown checkpoint (switchover right after a rejoin). Closes the
  double-failure window "standby back but not caught up, primary fails, standby promoted".
- **`conn_require_auth`** parameter: libpq `require_auth` for every connection of the agent to another node
  (probes, discovery, safety check, `primary_conninfo`, `pg_rewind`, `pg_basebackup`); local socket connections
  are not affected. Default empty (test setups); without it libpq accepts a server that skips authentication.
  Validated (syntax, libpq 16+); reloadable (`reload-agent`); standbys update `primary_conninfo` with their next
  monitor. Passed into the container in container mode.

### Documentation
- QUICKSTART: production checklist with a security block (`conn_require_auth`, `pg_hba` only from the node
  addresses, corosync crypto, optional TLS), monitoring of the record and of failed standby monitors, changing
  `conn_require_auth` without restarting the primary, what to do with a recorded node after losing the primary.
- doc/DESIGN_STALL_SAFE_SYNC.md: section 9 (decision, rules, authentication, lab results).
- QUICKSTART "When no fence device can confirm": fencing first, `fence_pgtwin` as the last level, the
  consequences of a full partition, `isolation_action`, and that two data centres whose services should go on
  on each side after a partition need a redundant gateway setup. Production checklist accordingly.
- QUICKSTART "A node that starts alone".

## [1.8.1] - 2026-11-11

Release notes: `releasenotes/RELEASE_v1.8.1.md`.

### Fixed
- **A standby that crashed shortly after a timeline switch could be left unrecoverable** (regression in 1.8.0,
  reported by dmkif with TC15, reproduced in the lab). After a switchover or a rejoin the standby's control file
  keeps the old checkpoint timeline until its first restartpoint (up to `checkpoint_timeout`). When it crashed in
  that window, the start path took the lag for a divergence and ran `pg_rewind`. Since 1.8.0 the signal files are
  moved aside for `pg_rewind`, so its single-user crash recovery ended recovery: it wrote an end-of-recovery
  checkpoint on the primary's current timeline at the end of the locally received WAL, at a position where the
  primary has a different record. `pg_rewind` then reported "no rewind required", and the standby failed every
  start or retry at that LSN (`record with incorrect prev-link`, `invalid resource manager ID`, `invalid record
  length`) until fail-count INFINITY. Only a basebackup helped. Before 1.8.0 the same false divergence led to a
  full basebackup.
  - The standby start compares the timeline the standby follows (for a node in recovery: the newest of the
    checkpoint timeline, the minimum recovery point's timeline and the history files) instead of the checkpoint
    timeline. A crashed standby restarts as a standby without `pg_rewind`.
  - `pg_rewind` is never run on a crashed standby (`in archive recovery`): it has no WAL of its own to rewind and
    is rebuilt with `pg_basebackup` if a divergence is reported. The signal files are moved aside only for a
    crashed primary.
  - Standbys already in that state are repaired: when the monitor's recovery gets "no rewind required" for a
    standby that cannot stream, it rebuilds with `pg_basebackup`; a standby start that fails at the same WAL
    position three times falls back to `pg_basebackup` like the missing-WAL case.
- **Acknowledged commits could be lost when both cluster rings failed without fencing** (1.8.0, dmkif, 4 ids in
  one run). Rule 1a relaxed `synchronous_standby_names` after a single failed probe of the peer's PostgreSQL; the
  peer was in the middle of its promotion. The probe result is now classified (answers / server error /
  unreachable); the monitor relaxes only after the peer has been unreachable for 6 s over at least two probes, and
  never when it answers or its server reports an error. The peer is probed once per monitor run.
- **With fencing, writes stayed blocked after a standby was fenced until it came back** (1.8.0, dmkif: 199 s,
  unbounded if the standby never returns). The post-stop notification only relaxed with an empty
  `pg_stat_replication`, but the walsender of a fenced or frozen standby stays listed until `wal_sender_timeout`.
  The notification now ends the walsender of the stopped peer and relaxes, and logs its decision. Fallback in the
  monitor: the cluster has recorded the peer as offline and clean (fenced or stopped).
- **Upgrade from 1.7.x could demote the primary** (1.8.0, dmkif: 2 of 4 upgrades, 93 s without primary). The
  permanent promotion score of earlier versions was deleted before the transient one was in the CIB. Now the
  transient value is set first and the permanent one is removed once the transient value is visible.
- **Every switchover took `wal_sender_timeout` longer** (1.8.0, dmkif: 69-77 s). Since 1.8.0 discovery via the VIP
  authenticates and succeeds, and the standby streamed from the VIP. At a demote the VIP is stopped first, the
  standby's connection hangs without a reset, and the old primary's shutdown waits for its walsender. Discovery now
  returns the node behind the VIP (matching `pg_postmaster_start_time()`), and the monitor moves a standby that
  streams from the VIP to that node (reload, no restart).
- **The promotion safety check blocked promotions while the old primary still answered** (e.g. cluster network
  down): it queried the primary as the postgres role without a password, and without `pg_read_all_stats` the
  replication user cannot read `sync_state`. It now queries as the replication user and names the missing grant.
  It skips the search for the old primary when the cluster has confirmed it is gone: with fencing when the node
  is offline and clean, in any case when the node is a member and no instance runs there (switchover). The search
  failed open after its connect timeouts and cost 4 s of every failover and 2-3 s of every switchover.
- The standby start no longer warns about an empty `synchronous_standby_names` (no effect on a standby, set by
  pgtwin on promote).

### Documentation
- QUICKSTART: `GRANT pg_read_all_stats TO replicator`.
- Downgrade to 1.7.x: set the permanent promotion score to 10 on every node first, then remove the transient one
  (release notes 1.8.0 and 1.8.1; order corrected by dmkif).
- `doc/DESIGN_STALL_SAFE_SYNC.md` section 8.5: findings and lab results with dual rings and power fencing.


Includes the fixes of the unreleased 1.7.12 and 1.7.13 from `dmkif/pgtwin` (hyphenated node names in
`synchronous_standby_names`, staying eligible for promotion when no primary exists). Release notes:
`releasenotes/RELEASE_v1.8.0.md`; design for the next step: `doc/DESIGN_STALL_SAFE_SYNC.md`.

### Changed
- **Stall-safe synchronous replication** (`doc/DESIGN_STALL_SAFE_SYNC.md`). A primary that stalls (paused VM,
  I/O hang) and continues later while its standby was promoted now waits instead of acknowledging, and is turned
  into a standby; the promoted node survives because its timeline went on. The behaviour for failing nodes is
  kept.
  - The primary monitor and the start path only tighten `synchronous_standby_names`; relaxing happens in promote
    and in the post-stop notification of the standby. Without fencing (no stop action, no notification) the
    monitor relaxes when the standby is offline and its PostgreSQL does not answer.
  - **Relative promotion score, transient** (was a permanent 10): base 10 as before; after a promotion the peer's
    last known score + 10000, back to 10 once a standby is in sync and the peer is at the base; demote and standby
    start drop to 10 at once. Of two primaries after a stall or partition the one promoted last survives the
    scheduler's demote decision, whichever node is DC, also against location and connectivity differences. Steady
    state scores (failover, ping rule, stickiness arithmetic) are unchanged.
  - A primary that finds the peer as primary on a newer timeline steps down (stop, `OCF_FAILED_PROMOTED`, restart
    as standby); a former primary never starts as a second primary.
  - With fencing, writes now block until the standby is fenced (63 s with the `crm cluster init` delays) instead
    of until the walsender gives up (~30 s).
- **`promotion_peer_wait` default 30 s (was 60 s), hard limit 40 s (was 100 s)**, both measured from the start of
  the check including primary discovery; no wait round is started that would end beyond the limit. The promote
  action stays well below 60 s.
- **Equal data states promote the node Pacemaker chose** instead of a tie-break by node name. The tie-break made
  `crm resource move` to the node with the larger name impossible (after a clean demote both states are always
  equal); Pacemaker never promotes two instances at once (promoted-max=1).
- **The replication slot is prepared on the standby** and kept at the REDO point of its last restartpoint, so it
  exists the moment the node is promoted. Created after the promotion it came too late: the checkpoint PostgreSQL
  runs right after the promotion completed first and could recycle the WAL a rewound old primary needs.
- QUICKSTART: `resource-stickiness=50` (was 100). The Promoted role gets the stickiness twice (directly and through
  the colocated VIP); with 100 a primary that lost its connectivity keeps the role (310 against 260).

### Fixed
- **Switchover took 49-104 s, now 19-30 s.** No libpq connection had a connect timeout: a discovery query to the
  just-moved VIP hung in TCP SYN retries for 39-72 s per call (found with resource tracing). The agent now exports
  `PGCONNECT_TIMEOUT` (default 5 s, passed into the container in container mode), discovery uses 2 s, and a peer
  that is leaving (standby, shutdown) is recognised before any query.
- **Discovery queries could never succeed** in a setup following QUICKSTART.md: VIP and node_list queries ran as the
  `postgres` role without a password. They now use the replication user on database `postgres`, as the `.pgpass`
  entries are documented for. Only the CIB fallback worked before.
- **The standby timeline was read from its last checkpoint**, which lags behind; a standby on the new timeline with
  the same LSN was judged older and refused the promotion. The newest timeline history file in `pg_wal` is used
  as well.
- **A demoting primary ran `pg_rewind` against the not yet promoted standby** on every switchover (timeline check
  in the standby start against a standby). The check now only compares with a node that is primary.
- **`pg_rewind` failed after every crash of the primary** (`standby mode is not supported by single-user servers`):
  pg_rewind completes the crash recovery in single-user mode, which refuses to run with `standby.signal`. A full
  `pg_basebackup` ran instead. The signal files are kept outside PGDATA while pg_rewind runs.
- **A consistent standby whose WAL is gone on the primary looped forever**: it starts, but the walreceiver fails
  with `requested WAL segment ... has already been removed`, and the monitor recovery answered with a pg_rewind
  that changes nothing. The monitor now detects the condition and rebuilds with `pg_basebackup` (1.7.10 covered only
  a failing start).
- **A standby vetoed its own promotion when its primary died and could not restart**, so no failover happened
  (lab: none after 180 s). The node stays eligible when the peer answers as a standby, or when it does not answer
  and the CIB shows no promoted instance (extends `fix/cold-start-eligible` from dmkif, whose peer query now also
  authenticates as the replication user).
- **Automatic standby initialization looped** when PGDATA held only files written by pgtwin itself
  (`postgresql.auto.conf`, signal files) but no cluster: `pg_basebackup` refused the non-empty directory. These
  files are removed first; anything else still stops with an error.
- Hyphenated node names in `synchronous_standby_names` (dmkif, 1.7.12): compare and list the application_name.
- The pre-basebackup version check never ran (`${PG_CTL}` was undefined; the variable is `PGCTL`).
- Agent metadata version (said 1.6.9) and `pgtwin.spec` (said 1.6.0) updated.

### Documentation
- QUICKSTART: Tumbleweed binary links without `/etc/alternatives`, `wal_log_hints = on`, `pg_hba.conf` entry for
  `replicator` on database `postgres`, no root-owned files in PGDATA, watchdog section (`kernel-default` on the
  Minimal VM), crmsh init/join with SBD, `fencing-enabled`, controlled startup after the cluster exists,
  copy-paste-safe resource examples with `vip`, required `migration-threshold`/`failure-timeout`, measured
  scoring with a `crm_simulate` recipe, failover-time breakdown of the fencing delays, recovery after a failover.
- QUICKSTART_DUAL_RING_HA: dual rings do not replace fencing; `rsc_defaults` instead of the ignored property.
- `doc/DESIGN_STALL_SAFE_SYNC.md`: design for stall-safe synchronous replication (not implemented).

### Tests
- New unit tests: `test/test-cold-start-eligible.sh` (8), `test/test-safe-sync-names.sh` (5);
  `test/test-promotion-data-state.sh` updated (28).
- `test/test-pgtwin-ha-suite.sh` no longer deletes the primary's data when started with the second node as primary,
  and refuses to delete a data directory when no primary exists.
- Lab (two KVM nodes, PostgreSQL 17.11, Pacemaker 3.0.3, SBD): HA suite 12/12; see the release notes for the
  failure matrix.

## [1.7.11] - 2026-10-27

### Fixed
- **Stale standby was promoted after a staggered shutdown of both nodes**
  - `check_promotion_safety()` took the fail-open branch ("Allowing promotion") when no primary was running, even
    though the peer was a cluster member. The node that booted first (the former standby) was promoted as soon as
    the former primary joined the cluster, and the newer data of the former primary was discarded.
  - Fix: `promotion_data_state_guard()` compares (timeline, replay LSN) with the peer before the existing checks;
    the node that is ahead is promoted, the other refuses; equal states are decided by cluster name; a peer that
    gives no usable state within the new parameter `promotion_peer_wait` (default 60 s, hard limit 100 s) is
    treated as unreachable and the node is promoted with a warning. `force_promotion=true` and
    `promotion_peer_wait=0` keep the old behaviour.
  - A peer that is shutting down or in standby is not waited for (`promote-peer-leaving`), so a clean reboot of the
    primary does not delay the failover.
  - A former primary (no `standby.signal`) that starts while the peer is a cluster member and no primary runs is
    started as standby, so the same comparison applies (primary dies, standby promoted and writing, new primary
    dies, old primary boots first: 116 acknowledged commits lost before the fix).
  - Log: `promotion-by-data-state: decision=...` with both data states.
  - Tests: `test/test-promotion-data-state.sh`; see `doc/FEATURE_PROMOTION_BY_DATA_STATE.md`.

## [1.7.10] - 2026-10-11

### Fixed
- **Replication slot created at promotion did not reserve any WAL**
  - `create_replication_slot()` called `pg_create_physical_replication_slot(name)` without `immediately_reserve`, so the new slot had `restart_lsn = NULL` and kept no WAL until a standby had connected through it
  - Replication slots are not copied to the standby, therefore every failover creates a fresh, empty slot on the new primary; a standby that stays away for a while finds its WAL recycled and can never catch up (`requested WAL segment ... has already been removed`)
  - Fix: create the slot with `immediately_reserve => true`; an existing slot that is idle and has no reserved WAL is dropped and recreated, a slot that already reserves WAL or is in use is left alone
  - Reproduction: `test/wal-removed-repro/slotcheck.sh`
- **Standby start loop when the required WAL is gone from the primary**
  - A standby whose WAL was already recycled on the primary waits in `waiting for WAL to become available`; `pg_ctl -w start` times out and the agent failed with `Failed to start PostgreSQL`. Pacemaker cleared the fail-count after `failure-timeout` and retried the identical start forever, as nothing ever fell back to `pg_basebackup`
  - The timeline check did not help: with equal timelines it does not run, and after a timeline divergence `pg_rewind` can answer `no rewind required` while the redo segment is still missing
  - Fix: if the start of a standby fails and the log lines written by that attempt contain `requested WAL segment ... has already been removed`, stop PostgreSQL and rebuild the standby with `pg_basebackup` (skipping `pg_rewind`), then defer to the monitor like the existing empty-PGDATA path. Only log lines written by the failed attempt are considered, with or without `logging_collector`
  - Reproduction: `test/wal-removed-repro/`
- **Standby start did not ensure its replication slot exists on the primary**
  - `finalize_standby_config()` writes `primary_slot_name`, but only the `pg_basebackup` path created the slot. After a `pg_rewind` recovery, a dropped slot or a rebuilt primary the walreceiver failed forever with `replication slot "..." does not exist`; the standby is consistent, so the start succeeded and nothing noticed that replication was down
  - Fix: before a standby starts, the agent checks the slot on the primary and creates it with `immediately_reserve` if it is missing. Best effort: if the primary cannot be reached the start continues as before
  - Reproduction: `test/wal-removed-repro/mkstandby-stream.sh`

### Documentation
- **NEW**: `test/wal-removed-repro/` - podman bench that reproduces all three failure modes against the real agent
- **NEW**: `releasenotes/RELEASE_v1.7.10.md` - Release notes with upgrade notes

---

## [1.7.6 - 1.7.9] - 2026-08 / 2026-09

Not recorded at release time; reconstructed from the git history (tag `v1.7.9`).

### Fixed (pgtwin)
- `discover_promoted_node()`: VIP-based discovery no longer breaks on `/32` VIPs (the VIP itself is the connectable identity) (#1)
- `parse_pgpass()`: default `.pgpass` path resolved from the real home directory of `pguser`, consistent with `ensure_pgpass()` (#2)
- `pgsql_demote()`: a self-discovered primary is rejected, so `primary_conninfo` can no longer point at the node itself (#4); the `node_list` fallback is verified before it is trusted
- `pgsql_start()`: after `recover_standby()` the start defers to the monitor while an asynchronous basebackup is running (#5)
- `set_promotion_eligibility()`: the promotion score is written to `master-<resource>` (the attribute Pacemaker reads) with a positive floor, so a recovering node does not contest promotion and a lone healthy primary is not demoted (#3)
- `start_async_basebackup()`: `pg_basebackup -c fast`, so a rejoining standby does not wait for a spread checkpoint

### Fixed (pgtwin-migrate)
- `setup_subscription()`: `copy_data` is configurable and defaults to `false` for the reverse direction (#6)
- `pgtwin_migrate_prepare_cutover_v2()`: checks the return code of `swap_vip_addresses` (#8)
- README: parameter names and required list match the script (#9)

---

## [1.7.5] - 2026-04-29

### Fixed
- **REGRESSION: New clusters stuck in async mode (introduced in v1.7.4)**
  - `get_safe_synchronous_standby_names()` returned `''` when Pacemaker node names didn't match `pg_stat_replication.application_name`
  - Affects new clusters and manually-configured standbys where `primary_conninfo` lacks an explicit `application_name`
  - Fix: name-mismatch case now returns `'*'` (sync with any standby) instead of `''`, with a log warning to help admin fix the `application_name`
  - The v1.7.4 fix (no standbys connected at all → `''`) is preserved

### Documentation
- **NEW**: `releasenotes/RELEASE_v1.7.5.md` - Release notes with decision table and upgrade guide

---

## [1.7.4] - 2026-03-30

### Fixed
- **CRITICAL: `get_safe_synchronous_standby_names()` caused write blocking on standby loss**
  - All four "no standby available" code paths returned `'*'` instead of `''` (empty)
  - `synchronous_standby_names = '*'` with no connected standbys blocks all PostgreSQL writes
  - Fix: return `''` (async mode) whenever no standbys are available; sync resumes automatically when standby reconnects
  - Affected scenarios: clone resource lookup failure, no Unpromoted nodes in cluster, no standbys streaming to PostgreSQL, Unpromoted nodes present but not yet streaming

### Documentation
- **NEW**: `releasenotes/RELEASE_v1.7.4.md` - Release notes with upgrade instructions

---

## [1.7.3] - 2026-01-19

### Added
- **NEW: pgtwin-migrate-setup v1.0.0** - Interactive setup wizard for migration configuration
  - Guided step-by-step configuration collection
  - Configuration file generation (reusable `.conf` files)
  - CRM snippet generation (ready-to-use Pacemaker configuration)
  - Validation of cluster connectivity, database access, VIP resources
  - Template support: load existing configs with `--config FILE`

### Added (pgtwin-migrate v2.0.0 EXPERIMENTAL)
- **Bidirectional Failover**: New `production_cluster` parameter replaces `cutover_ready`
  - Change `production_cluster` to switch which cluster is production
  - Supports failback (cutover → source) in addition to cutover (source → target)
  - Clean transition: old direction DELETED, new direction CREATED fresh
- **Dynamic Database Discovery**: Discovers databases at runtime from production cluster
  - No explicit `databases` parameter needed (auto-discover)
  - New databases detected automatically every 10th monitor cycle
  - Replication set up automatically for new databases
- **Direction-Aware Start Function**: Correctly handles both forward and reverse directions
  - Checks for publications matching current `production_cluster`
  - Sets up replication for the correct direction
  - Sets CIB state appropriately (`FORWARD_REPLICATION` or `CUTOVER_COMPLETE`)
- **New Database Auto-Setup**: Monitor detects databases without replication
  - Creates database on subscriber if it doesn't exist
  - Copies schema from publisher to subscriber
  - Creates publication and subscription with `copy_data=true`
  - Sets up DDL trigger

### Changed (pgtwin-migrate v2.0.0 EXPERIMENTAL)
- **Parameter Changes**:
  - `production_cluster` (NEW) - Which cluster should be production
  - `finalize_replication` (NEW) - When true, stop cleans up all replication infrastructure
  - `stability_timeout` (NEW) - Seconds to wait for cluster stability before cutover
  - `cutover_ready` (REMOVED) - Replaced by `production_cluster`
- Version bumped to 2.0.0 due to breaking parameter changes

### Changed (pgtwin v1.7.3)
- Version bump for release coordination (no functional changes from v1.7.2)
- For v1.7.2 changes (FQDN hostname mismatch bugfix), see RELEASE_v1.7.2.md

### Documentation
- **NEW**: `releasenotes/RELEASE_v1.7.3.md` - Complete release notes
- **NEW**: `README-pgtwin-migrate-setup.md` - Setup wizard documentation (planned)
- **UPDATED**: `CHANGELOG.md` - This entry

### Migration
- **pgtwin**: No changes required from v1.7.2
- **pgtwin-migrate v1.x → v2.0**:
  1. Complete any in-progress migrations
  2. Stop and delete old migration resource
  3. Deploy pgtwin-migrate v2.0
  4. Use pgtwin-migrate-setup to generate new configuration
  5. Test with non-production data first
- **WARNING**: pgtwin-migrate v2.0 parameter changes are breaking - requires reconfiguration

### Known Limitations (pgtwin-migrate v2.0)
- `max_logical_replication_workers` limit - PostgreSQL default is 4 workers, increase for many databases
- Initial sync for new databases uses `copy_data=true` (database must exist on subscriber)
- Complex schema changes during migration may need manual coordination

---

## [1.7.1] - 2026-01-05

### Added
- **EXPERIMENTAL: pgtwin-migrate v1.0.8** - Zero-downtime PostgreSQL migration agent
  - Orchestrates PostgreSQL cluster migrations via logical replication
  - Use cases: Major version upgrades, vendor migrations, hosting provider changes
  - Features: Bidirectional DDL replication, self-healing, cluster-wide state management, **multi-database migration**
  - Status: EXPERIMENTAL - test thoroughly before production use
  - Documentation: README-pgtwin-migrate.md, MIGRATION_DOCUMENTATION_INDEX.md

### Added (pgtwin-migrate v1.0.8)
- **Multi-Database Migration Support** - Migrate multiple databases in a single operation
  - New `databases` parameter: comma-separated list of databases to migrate
  - Example: `databases="postgres,myapp_prod,analytics,reporting"`
  - Per-database publications, subscriptions, replication slots, and DDL triggers
  - Per-database state tracking and lag monitoring
  - Atomic cutover for all databases together (single VIP swap)
  - Backward compatible with legacy `pgdatabase` parameter
  - Tested with 1-10 databases, scales linearly
  - Documentation: FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md

### Fixed (pgtwin-migrate v1.0.7)
- **Auto-stop after cutover completion**
  - Bug: Resource set target-role=Stopped in monitor, but if migration-state attribute was deleted before monitor ran, auto-stop never triggered
  - Fix: Set target-role=Stopped immediately in check_cutover_progress() when cutover completes (lines 2263-2270)
  - Impact: Resource automatically stops when migration completes, prevents restart loops
  - Kept monitor auto-stop as safety net for edge cases (manual restart, old version migration)

### Fixed (pgtwin v1.6.18)
- **CRITICAL**: Synchronous standby names handling (v1.6.18)
  - Bug: `update_application_name_in_config()` unconditionally wrote sync setting
  - Fix: Only write sync setting when rep_mode=sync
  - Impact: Prevents async clusters from being forced to sync mode
- **CRITICAL**: VIP colocation during failover (v1.6.16)
  - Bug: VIP started on demoting node instead of promoting node
  - Fix: Added colocation constraint check
  - Impact: Ensures VIP always on promoted (primary) node
- **CRITICAL**: XML cluster discovery during failover (v1.6.15)
  - Bug: CIB XML parsing incorrectly identified standby as primary
  - Fix: Enhanced XML parsing with proper Promoted role detection
  - Impact: Prevents operations on read-only nodes
- Configuration detection using postgres -C (v1.6.14)
- Parallel cluster discovery race condition (v1.6.13)
- Timeline check breaking cluster discovery (v1.6.13)
- Replication slot conflict handling (v1.6.9)
- Double-failure detection (v1.6.8)

### Changed
- Updated to version 1.7.0
- Enhanced logging and error messages throughout
- Improved synchronous replication handling (v1.6.17)
- Better single-node scenario handling (v1.6.13)

### Documentation
- Added README-pgtwin-migrate.md - Complete migration agent guide
- Added MIGRATION_DOCUMENTATION_INDEX.md - Full migration workflow
- Updated PGTWIN_CONCEPTS.md - Added pgtwin-migrate overview
- Enhanced QUICKSTART.md with migration references

# Changelog

All notable changes to pgtwin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.7] - 2025-12-23

### Fixed
- **CRITICAL**: Replication failure counter stuck at 1/5 (QA fix)
  - Bug: Counter read using `ocf_run` wrapper which captures stdout, counter always reset to 1
  - Fix: Removed `ocf_run` wrapper from counter read operation (line 1576)
  - Impact: Automatic recovery now triggers correctly after 5 consecutive failures
  - Code: `crm_attribute -G` now properly returns counter value
- **CRITICAL**: PGDATA permissions causing PostgreSQL startup failures (QA fix)
  - Bug: pg_basebackup creates PGDATA with 751 permissions, PostgreSQL requires 700 or 750
  - Fix: Added `chmod 750` at three PGDATA creation points (lines 1893, 2740, 3067)
  - Impact: Eliminates "data directory has invalid permissions" errors after basebackup
- **CRITICAL**: Replication slot creation before pg_basebackup (prevents WAL recycling race)
  - Bug: WAL segments could be recycled before standby retrieved them during long pg_basebackup
  - Fix: Create replication slot BEFORE starting pg_basebackup (lines 2678-2709)
  - Impact: Eliminates "requested WAL segment already removed" failures
  - Affects: Large databases, slow networks, or high WAL generation rates
- **Configuration Validation**: False wal_sender_timeout warnings (QA fix)
  - Bug: Code parsed `SHOW wal_sender_timeout` returning "30s", stripped to "30", compared as integer
  - Fix: Query `pg_settings` which returns milliseconds directly (lines 1162-1175)
  - Impact: Eliminates false warnings when timeout correctly set (e.g., 30s = 30000ms)
- **Log Noise**: Excessive PAM session logging from runuser (QA fix)
  - Bug: Every PostgreSQL operation logged 2 PAM entries (138 entries per 30 seconds)
  - Fix: Created `run_as_pguser()` helper using `setpriv` instead of `runuser` (lines 48-61)
  - Impact: 98% reduction in log noise (0-2 entries vs 138 per 30 seconds)
  - Changed: All 76 `runuser` calls replaced with `run_as_pguser`
- **Documentation**: Fixed duplicate order constraint in QUICKSTART.md
  - Bug: Two order constraints named "promote-before-vip" (Pacemaker rejects duplicate names)
  - Bug: Second constraint had wrong semantics: `postgres-clone:demote vip:start`
  - Fix: Renamed to `vip-stop-before-demote` with correct order: `vip:stop postgres-clone:demote`
  - Impact: QUICKSTART.md instructions now work correctly (previously would fail at crm configure)

### Added
- **Performance**: Automatic resource cleanup after basebackup completion
  - Self-triggered `crm_resource --cleanup` when pg_basebackup finishes
  - Uses `crm_node -n` to determine cluster node name (lines 2726-2768)
  - Performance: 98.4% faster for small databases (5s vs 5m 5s)
  - Eliminates 5-minute failure-timeout wait for administrators
  - Falls back to failure-timeout if cleanup command fails

### Changed
- Updated version to 1.6.7 and release date to 2025-12-23
- Enhanced description includes slot creation sequencing and auto-cleanup
- Consolidated multiple development versions (v1.6.8-v1.6.11) into single stable release
- **Container Mode**: Downgraded "container library not available" from warning to info level (QA fix)
  - Container mode is experimental, missing library should not generate warnings
  - Code change: `ocf_log warn` → `ocf_log info` (line 1782)
- **Privilege Dropping**: Replaced all `runuser` calls with `setpriv` for cleaner logging
  - New `run_as_pguser()` helper function provides consistent privilege dropping
  - Eliminates PAM session logging for PostgreSQL operations

### Testing
- ✅ Automated test suite: 12/12 tests passed (100%)
- ✅ Failover performance: ~4.5 seconds
- ✅ Initialization speedup: 98.4% improvement
- ✅ Zero data loss in all scenarios
- New test suite v1.1 with fixed application_name, pg_rewind timeout, and slot detection checks

### Documentation
- **NEW**: `RELEASE_v1.6.7.md` - Consolidated release notes with all improvements
- **NEW**: `test/test-pgtwin-ha-suite.sh` - Comprehensive automated test suite (12 tests)
- **NEW**: `doc/TEST_SUITE_FIXES.md` - Test suite accuracy improvements documentation
- **NEW**: `QUICKSTART_DUAL_RING_HA.md` - ⚠️ Experimental dual-ring Corosync guide (alternative to SBD)
- **NEW**: `postgresql.custom.conf` - Sample PostgreSQL configuration for HA clusters
  - Minimal required settings for pgtwin resource agent
  - Includes critical `restart_after_crash = off` setting
  - Ready-to-use template for new deployments
- **UPDATED**: `pgsql-resource-config.crm` - Enhanced cluster configuration
  - Added resource-stickiness=100 to prevent unnecessary failback
  - Added failure-timeout=5m and migration-threshold=5
  - Added ping-gateway resource for network connectivity monitoring
  - Added location constraint to prefer nodes with working network connectivity
- **UPDATED**: `QUICKSTART.md` - Added PostgreSQL binary linking instructions (section 1.1)
  - Manual symlink creation for postgresql17-server binaries
  - Two-tier structure via /etc/alternatives for easy version switching
  - Verification commands included
- **UPDATED**: `QUICKSTART.md` - Container mode sections marked as ⚠️ experimental
- **UPDATED**: `README.md` - Added reference to dual-ring experimental guide
- **UPDATED**: `CHANGELOG.md` - This entry

### Migration
- Fully backward compatible with v1.6.6
- No cluster configuration changes required
- Recommended: Run test suite after upgrade to validate functionality
- See RELEASE_v1.6.7.md for complete upgrade instructions

**Note**: This release consolidates critical bug fixes for production deployments. Immediate upgrade recommended for clusters experiencing basebackup failures or long administrator wait times.

## [1.6.6] - 2025-12-09

### Fixed
- **CRITICAL**: Fixed pg_basebackup configuration finalization bug that created empty `primary_conninfo` values
  - Bug caused 100% replication failure after pg_basebackup recovery (affects v1.6.0-v1.6.5)
  - Root cause: Code attempted to read values from file after deleting it
  - Fix: Read values before deletion in `check_basebackup_progress()`
  - New unified `finalize_standby_config()` function ensures correct config (lines 1838-1912)
  - Prefers direct file update when PostgreSQL stopped, falls back to ALTER SYSTEM
  - Safety check in `pgsql_start()` detects and auto-fixes broken configurations
  - Used in all recovery paths: pg_rewind, pg_basebackup (async), manual recovery

### Added
- **Automatic Standby Initialization**: Zero-touch deployment from empty PGDATA
  - New `is_valid_pgdata()` function detects empty/missing/invalid PGDATA (lines 1483-1506)
  - Auto-init logic in `pgsql_start()` triggers pg_basebackup automatically (lines 1530-1590)
  - Updated `pgsql_validate()` to allow empty PGDATA (lines 2360-2375)
  - Prerequisites: Only `.pgpass` file with replication credentials required
  - Use cases: Fresh deployment, disk replacement, corrupted data recovery
  - Disk replacement simplified: 10+ steps → 3 steps
- **Pacemaker Notify Support**: Dynamic synchronous replication management
  - New `pgsql_notify()` action handler (lines 2393-2429)
  - `enable_sync_replication()` - enables sync when standby starts (lines 2383-2391)
  - `disable_sync_replication()` - disables sync when standby stops (lines 2373-2381)
  - Prevents write blocking when standby fails
  - Automatically switches between sync and async based on cluster state
  - Requires `notify="true"` in clone meta configuration
  - Handles post-start, post-stop, post-promote, pre-demote events

### Changed
- Updated version to 1.6.6 and release date to 2025-12-09
- Enhanced description includes automatic standby initialization and notify support
- Configuration finalization now unified across all recovery methods
- PGDATA validation more lenient to support auto-initialization

### Documentation
- **NEW**: `doc/BUGFIX_PG_BASEBACKUP_FINALIZATION.md` - Critical bug fix analysis
- **NEW**: `doc/FEATURE_AUTO_INITIALIZATION.md` - Complete auto-init guide
- **NEW**: `doc/FEATURE_NOTIFY_SUPPORT.md` - Complete notify support guide
- **UPDATED**: `MAINTENANCE_GUIDE.md` - Simplified disk replacement procedure
- **UPDATED**: `CHANGELOG.md` - This entry
- **NEW**: `RELEASE_v1.6.6.md` - Complete release notes

### Migration
- **CRITICAL**: Immediate upgrade recommended to fix configuration bug
- Fully backward compatible with v1.6.x
- No cluster configuration changes required
- Optional: Enable notify support by adding `notify="true"` to clone meta
- See RELEASE_v1.6.6.md for complete upgrade instructions

## [1.6.5] - 2025-11-10

### Added
- **Container Mode Support**: Seamless Podman/Docker container deployment (Phase 1)
  - New container library: `pgtwin-container-lib.sh`
  - Automatic container runtime detection (Podman primary, Docker fallback)
  - Transparent PostgreSQL command wrappers (pg_ctl, psql, pg_basebackup, etc.)
  - Container lifecycle management (start, stop, cleanup)
  - New OCF parameters: `container_mode`, `container_name`, `container_image`, `pg_major_version`
  - Container mode validation in `pgsql_validate()`
  - No code changes needed in main agent for container vs bare-metal operation

### Changed
- Added container mode support throughout all PostgreSQL operations
- Enhanced metadata with container-specific parameters
- Installation now includes container library deployment

### Documentation
- **NEW**: `CONTAINER_MODE_IMPLEMENTATION.md` - Container mode technical guide
- **NEW**: `RELEASE_v1.6.5_SUMMARY.md` - Container mode release summary
- **UPDATED**: Installation instructions include container library

## [1.6.4] - 2025-11-07

### Changed
- Prepared release package for GitHub distribution
- Updated documentation and version tracking
- All files synchronized with latest v1.6.3 codebase

### Status
- Stable release ready for production deployment
- Includes all fixes from v1.6.1, v1.6.2, and v1.6.3
- No functional changes from v1.6.3

## [1.6.3] - 2025-11-05

### Fixed
- **CRITICAL**: Fixed cluster node name handling - resource agent now correctly uses Pacemaker cluster node name instead of system hostname
  - Added `get_cluster_node_name()` helper function using `crm_node -n`
  - Fixed 6 locations using `hostname -s` for `crm_attribute` calls
  - Prevents UUID mapping errors when cluster node names differ from hostnames
  - Critical for VM/cloud environments with generic hostnames
- **QUICKSTART.md**: Fixed PostgreSQL startup sequence - PostgreSQL must be running before creating replication user
- **QUICKSTART.md**: Added replication slot creation step before `pg_basebackup`
- **QUICKSTART.md**: Simplified ocf-tester verification instructions

### Changed
- All `crm_attribute` operations now use cluster node name from `crm_node -n`
- Node list comparisons use cluster node name for accuracy

### Impact
- Fixes crm_attribute failures in environments where cluster node name ≠ hostname
- Backward compatible - falls back to `hostname -s` if `crm_node` unavailable
- No configuration changes required for existing clusters

## [1.6.2] - 2025-11-03

### Documentation
- **README.md**: Added "Expected Timing" section with detailed performance metrics
  - Automatic failover: 30-60 seconds breakdown
  - Manual failover: 15-30 seconds
  - Node recovery timing (pg_rewind vs pg_basebackup)
  - Replication lag expectations (sync/async modes)
- **QUICKSTART.md**: Integrated complete inline Production Checklist
  - PostgreSQL configuration checklist
  - Replication configuration checklist
  - Cluster configuration checklist
  - Testing verification checklist
  - Monitoring setup checklist
- **PROJECT_SUMMARY.md**: Cleaned up parent repository references

### Changed
- All documentation now self-contained within pgtwin repository
- Focus on operational timing metrics instead of synthetic benchmarks
- No code changes - documentation-only release

## [1.6.1] - 2025-11-03

### Fixed
- **CRITICAL**: Fixed replication failure counter not incrementing (removed `ocf_run` wrapper from GET operations)
- **CRITICAL**: Added missing `passfile` parameter to `primary_conninfo` in 3 locations
  - `pgsql_demote()` function
  - `recover_standby()` after pg_rewind
  - `check_basebackup_progress()` after pg_basebackup
- **CRITICAL**: Fixed CIB parsing returning "*" instead of hostname (improved `crm_mon` parsing)
- **CRITICAL**: Added missing `PGPASSFILE` environment variable for pg_rewind and pg_basebackup
- **CRITICAL**: Fixed `pg_basebackup` exit code handling (accepts exit code 1 as success with warnings)
- **CRITICAL**: Prevented replication slot recreation when slot already exists

### Impact
- Automatic recovery feature from v1.6.0 now fully functional
- Replication reconnection after demote now works correctly
- pg_rewind and pg_basebackup authentication fixed
- All 6 critical bugs preventing v1.6.0 from working are resolved

## [1.6.0] - 2025-11-03

### Added
- **Automatic Replication Recovery**: Monitor function now detects replication failures and automatically triggers recovery
  - Tracks replication health on standby nodes
  - Incremental failure counter with configurable threshold (`replication_failure_threshold` parameter, default: 5)
  - Automatically triggers `pg_rewind`/`pg_basebackup` when threshold exceeded
- **Dynamic Promoted Node Discovery**: New `discover_promoted_node()` function finds current primary using multiple methods:
  - Method 1: Query VIP directly (fastest, most reliable)
  - Method 2: Scan all nodes in `node_list`
  - Method 3: Parse Pacemaker CIB (fallback)
- **Enhanced Monitor Function**: Standby nodes now actively monitor WAL receiver status
- **Enhanced Demote Function**: Uses dynamic discovery to find promoted node for replication setup
- **New Parameters**:
  - `vip`: Virtual IP address for promoted node discovery (optional but recommended)
  - `replication_failure_threshold`: Number of monitor cycles before triggering automatic recovery (default: 5)

### Known Issues
- Replication failure counter may not increment correctly in some scenarios (FIXED in v1.6.1)
- Missing `passfile` parameter in `primary_conninfo` when using `.pgpass` authentication (FIXED in v1.6.1)

### Technical Details
- All v1.6 features are backwards compatible - clusters can upgrade without configuration changes
- Dynamic discovery significantly improves demote reliability in complex failure scenarios
- Automatic recovery reduces manual intervention for timeline divergence issues

## [1.5.0] - 2025-11-02

### Added
- **Enhanced Configuration Validation**: 6 new PostgreSQL configuration checks on startup
  - **CRITICAL**: `restart_after_crash` must be `off` (prevents split-brain)
  - **WARNING**: `wal_sender_timeout` < 10s (prevents false disconnections)
  - **WARNING**: `max_standby_streaming_delay` = -1 (prevents unbounded lag)
  - **WARNING**: `archive_command` error handling validation
  - **NOTICE**: `listen_addresses` security review
- **Runtime Archive Monitoring**: Continuous monitoring for archive failures on primary
  - Detects accumulating archive failures during monitor operations
  - Logs warnings with failure counts and timestamps
  - Prevents silent archive failures that could block writes
- **Comprehensive PostgreSQL Configuration Guide**: New `README.postgres.md` with:
  - Complete configuration reference
  - "Getting Started with HA PostgreSQL" tutorial
  - Critical and dangerous configuration options explained
  - Performance tuning and security considerations
  - Troubleshooting guide

### Changed
- Configuration validation now blocks startup on CRITICAL errors
- Archive failure monitoring runs on every primary monitor cycle (interval: 3s)

## [1.4.0] - 2025-11-01

### Fixed
- **CRITICAL**: Fixed promotion failure - `pg_ctl promote` now handles `standby.signal` removal automatically
  - Removed manual `rm -f standby.signal` which caused permission errors
  - PostgreSQL properly manages `standby.signal` during promotion
- **CRITICAL**: Added dual location constraints for proper failover migration
  - Both nodes now have `role=Promoted` score assignments
  - Enables bidirectional failover (psql1 ↔ psql2)

### Added
- **Automatic application_name Management**: Resource agent updates `application_name` in `postgresql.auto.conf`
  - On start: Updates to configured value or sanitized hostname
  - On promote: Ensures consistency between primary and standby
  - Eliminates manual synchronous_standby_names mismatches
- **STONITH/SBD Configuration**: Cluster now includes proper fencing
  - `stonith-enabled=true` with SBD device
  - `have-watchdog=true` for split-brain protection
  - `priority-fencing-delay=60s` for safer fencing

### Changed
- Promotion process now relies entirely on `pg_ctl promote` for file management
- Location constraints now explicitly include `role=Promoted` qualifier
- Default cluster configuration includes STONITH device

## [1.3.0] - 2025-10-31

### Added
- **Configuration Validation Framework**: 8 comprehensive checks run on every PostgreSQL start
  - PostgreSQL version compatibility check (17.x)
  - Critical replication settings validation (`wal_level`, `max_wal_senders`, `hot_standby`)
  - Archive mode configuration check
  - Listen addresses validation
  - Replication user existence verification
  - Replication slot configuration check
  - VIP parameter validation
  - Synchronous replication mode verification
- Early startup blocking for critical misconfigurations
- Detailed error messages for each validation failure
- Prevents cluster startup with unsafe configurations

## [1.2.0] - 2025-10-30

### Changed
- **Disk Space Calculation Refactoring**: Switched from logical database size to actual filesystem usage
  - Now uses `du -sb $PGDATA` for accurate total space requirements
  - Includes all data files, WAL, logs, temp files, and metadata
  - Backup mode: `(actual_usage × 2) + 10% safety margin`
  - No-backup mode: `(actual_usage × 1) + 10% safety margin`
- More accurate disk space safety margin calculations
- Improved error messages showing required vs available space

### Removed
- `pg_database_size()` based disk calculations (too narrow, missed critical space usage)

## [1.1.0] - 2025-10-29

### Added
- **Application Name Validation**: Enforces `[a-zA-Z0-9_]` character set
  - Automatic sanitization (hyphens → underscores) when using hostname fallback
  - Validation prevents PostgreSQL replication parsing issues
- **Disk Space Pre-Check**: Validates sufficient space before `pg_basebackup`
  - Checks available space on PGDATA filesystem
  - Accounts for backup mode (2× space) vs no-backup mode (1× space)
  - Prevents failed basebackups due to insufficient space
- **Backup Mode Semantics**: Clear distinction between backup and no-backup modes
  - `backup_before_basebackup=true`: Moves data to `.backup.<timestamp>` (recoverable)
  - `backup_before_basebackup=false`: Immediate permanent deletion (50% space savings)
- **Asynchronous pg_basebackup**: Long-running basebackups execute in background
  - Prevents Pacemaker monitor timeouts
  - Progress tracking in `${PGDATA}/.basebackup.log`
  - State file: `${PGDATA}/.basebackup_in_progress`
  - Configurable timeout via `basebackup_timeout` parameter (default: 3600s)
- **Enhanced .pgpass Support**: Automatic credential extraction
  - Parses `pgpassfile` parameter for replication credentials
  - Extracts host, port, user, password for `pg_basebackup` and `pg_rewind`
  - Fallback logic for credential discovery

### Parameters Added
- `basebackup_timeout` (default: 3600s): Maximum time for basebackup operation
- `pgpassfile` (optional): Path to .pgpass file for credential management
- `backup_before_basebackup` (default: false): Enable/disable backup mode

## [1.0.0] - 2025-10-28

### Initial Release
- PostgreSQL 17 High Availability support
- Physical streaming replication with replication slots
- Automatic failover with Pacemaker
- Virtual IP (VIP) management
- `pg_rewind` support for timeline reconciliation
- Synchronous and asynchronous replication modes
- Basic configuration validation
- WAL archiving support
- Comprehensive logging and error handling

[1.6.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.6.0
[1.5.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.5.0
[1.4.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.4.0
[1.3.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.3.0
[1.2.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.2.0
[1.1.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.1.0
[1.0.0]: https://github.com/yourusername/pgtwin/releases/tag/v1.0.0
