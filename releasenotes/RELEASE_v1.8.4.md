# pgtwin v1.8.4 Release Notes

**Release date:** 2026-11-16
**Type:** bug fix release; upgrade required before a cluster gets more than two nodes (for example a second
pgtwin pair for `pgtwin-migrate`). Contains pgtwin-migrate 2.1.0, **experimental**, review requested.

## Overview

| # | Problem in 1.8.3 | Impact |
|---|---|---|
| 1 | With more than two cluster nodes, pgtwin took the first other node of the whole cluster as its peer | a pair could record and check a node of the other pair instead of its own standby; in the lab a standby that was not in sync was promoted alone, **481 acknowledged commits lost** |
| 2 | pgtwin-migrate 2.0.0: the cutover did not set the old production read-only and read a failing lag query as "in sync" | acknowledged commits lost in every cutover under load (dmkif: 220, 53, 213, 553; lab: confirmed) |
| 3 | pgtwin-migrate 2.0.0: missing slots were recreated at the current position, failed subscriptions reported as created, the resource stopped itself after a cutover | the mirror could miss changes without any sign; no one watched it after a cutover |

## 1. pgtwin: the peer is the other node of `node_list`

pgtwin decides several things about "the peer": whom to record as not in sync before relaxing to async, when
to relax, the promotion safety check, the data comparison before a promotion, whether a node that starts is
alone, and the stale-primary check. Until 1.8.3 the peer was the first other node of the Pacemaker cluster
(five separate detections). With two nodes that is always right. With a second pgtwin pair in the same cluster
(PG17 pair pg1/pg2, PG18 pair pg3/pg4) both PG18 nodes took pg1 as their peer:

- pg3's promotion check looked at pg1, and its record went to pg1 instead of pg4.
- A name not in `node_list` was replaced by the first `node_list` entry: pg3's peer checks asked pg3 itself.
- When pg4 stopped, pg3 went async without recording pg4. When pg3 then stopped and pg4 started, pg4 was not
  alone (pg1 is a member) and promoted with older data: 481 acknowledged commits missing.

1.8.4 has one source for the pair (`pgtwin_pair_nodes`, `pgtwin_peer`, `pgtwin_peer_member`,
`pgtwin_peer_host`), and every decision uses it. The same lab test: the record goes to pg4, pg4 stays a
standby while it is alone, all acknowledged commits are present. Unit test: `test/test-pair-peer.sh`.

**`node_list` is required when the cluster has more than two nodes.** It must name exactly the two nodes of
this PostgreSQL cluster, this node included; start and `validate-all` refuse otherwise, and the monitor logs the
problem every 5 minutes. A two-node cluster may still leave it empty.

## 2. pgtwin-migrate 2.1.0 (experimental)

Version 2.1.0 stays experimental; the package moves to 2.x once pgtwin-migrate is considered stable.

### Sanity checks

On start, `validate-all` and before every cutover: both clusters are pgtwin clones, each `node_list` names
exactly its own two nodes, the lists do not overlap, each clone runs only on its own nodes, pgtwin is 1.8.4 or
newer, and each clone has a `-INFINITY` location with `resource-discovery=never` for the other pair's nodes
(dmkif: a probe of one clone stopped the other cluster's PostgreSQL). More than two votes without
`no-quorum-policy=ignore` gives a warning. Unit test: `test/test-migrate-sanity.sh`.

### Cutover

| Step | 2.0.0 | 2.1.0 |
|---|---|---|
| 0 | stability wait inside the monitor (outlasted its timeout) | stability wait in the background process; slots of the new direction created in advance |
| 1 read-only | `ALTER SYSTEM` and reload in one transaction: refused, error discarded | verified read-only, open client sessions over TCP ended, migration user exempted |
| 2 sync | query on a column that does not exist, read as lag 0 | every slot of the old direction must confirm the WAL position after step 1; missing slot or no answer aborts |
| 4 new direction | full setup with `copy_data=true` after a cutover back; errors reported as success | on the slots of step 0, no data or schema copy, slots advanced to now, then enabled; every error fatal |
| before 5 | - | every slot of the new direction must exist, else the VIP stays and the cutover rolls back |

Lab, writer through the production VIP, four cutovers in both directions: **0 acknowledged commits lost**.
Without an acknowledged write: 35 to 62 s before the window reduction, **about 11 s** after it (three
databases). Clients see "read-only transaction" errors, never an acknowledgement that is lost later.

### Mirror health

- A missing slot (failover of the publishing pair) or a publication without its subscription is reported as
  "Mirror incomplete" by start and monitor, with the resync steps. It is no longer recreated at the current
  position, which hid a gap (dmkif: 53 and 553 commits).
- The resource no longer stops itself after a cutover; the monitor checks the active direction.
- The database list of a cutover comes from the current production, not from the requested one.
- The old direction's DDL trigger is dropped (wrong name before, it survived every cutover).
- CIB lookups via `cibadmin` instead of crmsh (0.03 s instead of 0.4 s, four per `psql` call).

### Still open, review welcome

- Failover slots (PostgreSQL 17+), so the mirror survives a failover of the publishing pair.
- The resync text says to drop the database; for `postgres` the tables should be emptied instead.
- `pg_bindir` is not in pgtwin's metadata.
- A requested cutover starts with the next 5th monitor cycle; the window grows by about 2 s per database.
- Sequences and roles are not replicated.

## Upgrade notes

- **Before a third node joins: set `node_list` on every pgtwin clone**, two nodes each:
  `crm resource param <primitive> set node_list "<node1> <node2>"`. Clusters that stay at two nodes need
  nothing.
- **Replace agents by copy + rename** (`install -m 755 pgtwin pgtwin.new && mv pgtwin.new pgtwin`). Lab: an agent
  overwritten in place while a monitor ran made bash read a half-written file; the primary's monitor failed hard
  and Pacemaker moved the primary. All install instructions say so now. `make install` and RPM updates are safe.
- pgtwin-migrate: add `op monitor interval=30s timeout=60s` if the resource was created from README Option B
  without it; without a monitor no cutover starts. The cutover sets
  `ALTER ROLE <migration_dbuser> SET default_transaction_read_only = off` itself.
- `fence_pgtwin`: only its version string changed.

## Documentation

- README-pgtwin-migrate: "Preparing the clusters" (adding nodes with `crm cluster join` and the properties it
  changes, `resource-discovery=never`, `wal_level` with a rolling restart, migration user, `pg_hba.conf`,
  `.pgpass` with `*`, replication VIPs), the cutover as it runs now, known limitations.
- MIGRATION_DOCUMENTATION_INDEX lists only shipped documents.
- `doc/STATE_MATRIX.md` (draft): rules, dimensions and reachable states, including four nodes and logical
  subscribers; lab results.
