# pgtwin Test Suite

**Version**: 1.1
**Last Updated**: 2025-12-17

## Overview

Comprehensive automated test suite for pgtwin HA cluster. Tests all major functionality including replication slots, automatic initialization, configuration validation, migration scenarios, and file ownership.

## Quick Start

```bash
./test-pgtwin-ha-suite.sh <VIP_ADDRESS>
```

**Example**:
```bash
./test-pgtwin-ha-suite.sh 192.168.122.20
```

## Test Coverage

The suite runs **12 comprehensive tests**:

1. ✅ Replication slot automatic creation
2. ✅ Replication slot size monitoring
3. ✅ Handle missing replication slot during basebackup
4. ✅ Automatic standby initialization (empty PGDATA)
5. ✅ Automatic PostgreSQL variable settings (application_name)
6. ✅ Prevent misconfiguration: restart_after_crash
7. ✅ Prevent misconfiguration: wal_sender_timeout
8. ✅ Migration with pg_rewind (timeline divergence recovery)
9. ✅ Migration with pg_basebackup (with replication slot)
10. ✅ Correct sync replication mode after migration
11. ✅ File ownership verification
12. ✅ PostgreSQL version validation

## Default Configuration

Uses standardized defaults from QUICKSTART.md:

| Parameter | Default Value |
|-----------|---------------|
| Node 1 | psql1 (192.168.122.60) |
| Node 2 | psql2 (192.168.122.120) |
| PostgreSQL Port | 5432 |
| PGDATA | /var/lib/pgsql/data |
| Replication User | replicator |
| Slot Name | ha_slot |

**No manual configuration required** - Just provide the VIP address.

## Expected Results

**v1.6.7 Release**:
- **Expected**: 12/12 tests pass (100%)
- **Duration**: 5-15 minutes (depending on database size)
- **Output**: Colorized console output + detailed log files

## Output Files

1. **test-results-YYYYMMDD-HHMMSS.txt** - Test results summary
2. **test-detailed-YYYYMMDD-HHMMSS.log** - Detailed debug log
3. **test-diagnostics-YYYYMMDD-HHMMSS/** - Diagnostic files for failures (if any)

## Features (v1.1)

### Automatic Diagnostic Gathering

When tests fail, the suite automatically collects:
- Cluster status from both nodes
- Pacemaker logs (full + error-only)
- PostgreSQL logs and configuration
- Replication status and slot information
- File ownership verification
- Basebackup progress logs

### Automated Failure Analysis

Each failure gets analyzed automatically:
- Diagnosis of root cause
- Severity assessment
- Determination if pgtwin issue or test issue
- Recommendations for resolution

### Test Accuracy Improvements (v1.1)

Fixed 3 misleading test errors:

1. **Test 5**: Now checks server-side application_name (not psql client override)
2. **Test 8**: Increased timeout from 10s to 30s (allows pg_rewind or basebackup fallback)
3. **Test 9**: Now checks Pacemaker logs + slot state (not pg_basebackup output)

## CI/CD Integration

### Jenkins Example

```groovy
pipeline {
    agent any
    stages {
        stage('Test pgtwin Cluster') {
            steps {
                sh './github/test/test-pgtwin-ha-suite.sh 192.168.122.20'
            }
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'test-*.txt,test-*.log,test-diagnostics-*/**'
        }
    }
}
```

### Parsing Results

```bash
#!/bin/bash
RESULT_LINE=$(./test-pgtwin-ha-suite.sh 192.168.122.20 | grep "^SUMMARY:")

# Extract values
TOTAL=$(echo "$RESULT_LINE" | sed 's/.*Tests=\([0-9]*\).*/\1/')
PASSED=$(echo "$RESULT_LINE" | sed 's/.*Pass=\([0-9]*\).*/\1/')
STATUS=$(echo "$RESULT_LINE" | sed 's/.*Status=\([A-Z]*\).*/\1/')

if [ "$STATUS" = "SUCCESS" ]; then
    exit 0
else
    exit 1
fi
```

## Troubleshooting

### Cannot Connect to Nodes

```bash
# Verify SSH access
ssh root@psql1 hostname
ssh root@psql2 hostname

# Check /etc/hosts
grep psql /etc/hosts
```

### Tests Timeout

```bash
# Check cluster status
ssh root@psql1 "crm status"

# Monitor Pacemaker logs
ssh root@psql1 "journalctl -u pacemaker -f"
```

### Specific Test Failures

Review diagnostic files:
```bash
cd test-diagnostics-YYYYMMDD-HHMMSS/test_N_test_name/
cat analysis.txt
cat README.txt
```

## Version History

- **v1.1** (2025-12-17): Test accuracy improvements
  - Fixed Test 5: Check server-side application_name
  - Fixed Test 8: Increased pg_rewind timeout
  - Fixed Test 9: Check Pacemaker logs + slot state
  - Expected pass rate: 12/12 (100%)
  - Automatic diagnostic gathering
  - Automated failure analysis

- **v1.0** (2025-12-17): Initial release
  - 12 comprehensive tests
  - Default configuration from QUICKSTART.md
  - Colorized output
  - Detailed logging

## Documentation

For complete documentation, see:
- `../doc/TEST_SUITE_FIXES.md` - Test accuracy improvements
- `../RELEASE_v1.6.7.md` - Release notes
- `../CHANGELOG.md` - Complete changelog

## Support

For issues with the test suite:
1. Check detailed logs: `test-detailed-*.log`
2. Review diagnostics: `test-diagnostics-*/*/analysis.txt`
3. Verify cluster status: `crm status`
4. Check Pacemaker logs: `journalctl -u pacemaker`

## License

Same as pgtwin project (GPL-2.0-or-later)
