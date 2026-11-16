# pgtwin-migrate documentation

**Status**: pgtwin-migrate v2.1.0 (pgtwin 1.8.4), EXPERIMENTAL. Test thoroughly before production use.

## Documents in this distribution

| Document | Content |
|----------|---------|
| [README-pgtwin-migrate.md](README-pgtwin-migrate.md) | Installation, preparing the clusters (adding nodes, `wal_level`, user, `pg_hba.conf`, `.pgpass`, replication VIPs), resource configuration, cutover, failback, finalization, troubleshooting |
| [PGTWIN_CONCEPTS.md](PGTWIN_CONCEPTS.md) | How pgtwin and pgtwin-migrate work together |
| [doc/FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md](doc/FEATURE_MULTI_DATABASE_MIGRATION_v1.0.8.md) | Migrating several databases |
| [doc/BUGFIX_AUTO_STOP_TIMING_v1.0.7.md](doc/BUGFIX_AUTO_STOP_TIMING_v1.0.7.md) | Auto-stop timing |
| [doc/STATE_MATRIX.md](doc/STATE_MATRIX.md) | Cluster states; section 7 covers four nodes and logical subscribers |

Earlier versions of this index listed a planning worksheet, an admin preparation guide, a cutover procedure and a
cleanup guide. Those were written for v1.x, are not part of this distribution and do not describe v2.x. The
preparation steps they covered are now in README-pgtwin-migrate.md.

## Workflow (v2.0)

1. **Prepare** both clusters: README-pgtwin-migrate.md, "Preparing the clusters".
2. **Configure** the resource: `pgtwin-migrate-setup`, or README "Option B".
3. **Start**: `crm resource start migration-forward`. Databases are discovered on the production cluster,
   publications and subscriptions are created, and the initial copy runs.
4. **Run** as long as needed. New databases are picked up by the monitor.
5. **Cut over**: change `production_cluster`. The agent sets the old side read-only, waits until the mirror has
   confirmed everything, then moves the VIP (README, "Cutover Phase"). Writes fail for about 11 s.
6. **Fail back** if needed by changing `production_cluster` back; the same steps run in the other direction.
7. **Finalize**: set `finalize_replication=true`, then stop the resource.

## Key commands

```bash
crm status
crm_attribute -G -n migration-state -q

# On the subscriber: subscription state
sudo -u postgres psql -x -c 'SELECT * FROM pg_stat_subscription;'

# On the publisher: what each pgtwin-migrate slot has confirmed
sudo -u postgres psql -c "SELECT slot_name, confirmed_flush_lsn, pg_current_wal_lsn()
                          FROM pg_replication_slots WHERE slot_name LIKE 'pgtwin_migrate_%';"
```
