# Building and Installing pgtwin

This guide covers various methods for building, installing, and packaging pgtwin.

## Quick Install (No Build Required)

pgtwin is a shell script, so you can install it directly without building:

```bash
# Clone or download the repository
git clone https://github.com/yourusername/pgtwin.git
cd pgtwin

# Install using make
sudo make install

# Or install manually
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/
sudo chmod +x /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

## Building RPM Package

### Prerequisites

For SUSE/openSUSE:
```bash
sudo zypper install rpmbuild rpm-build
```

For RHEL/CentOS/Rocky:
```bash
sudo dnf install rpm-build rpmdevtools
```

### Build Steps

1. **Create source tarball:**
   ```bash
   make tarball
   ```

2. **Build RPM:**
   ```bash
   make rpm
   ```

   This will create:
   - `~/rpmbuild/RPMS/noarch/pgtwin-1.6.0-1.noarch.rpm`
   - `~/rpmbuild/SRPMS/pgtwin-1.6.0-1.src.rpm`

3. **Install RPM:**
   ```bash
   sudo rpm -ivh ~/rpmbuild/RPMS/noarch/pgtwin-1.6.0-1.noarch.rpm
   ```

### RPM Contents

The RPM package includes:
- `/usr/lib/ocf/resource.d/heartbeat/pgtwin` - OCF resource agent
- `/usr/share/doc/pgtwin/` - Documentation files
  - README.md
  - CHANGELOG.md
  - QUICKSTART.md
  - CHEATSHEET.md
  - PROJECT_SUMMARY.md
  - LICENSE
  - VERSION

## Manual Installation

If you prefer not to use make or RPM:

```bash
# Install OCF agent
sudo install -d -m 0755 /usr/lib/ocf/resource.d/heartbeat
sudo install -m 0755 pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Install documentation (optional)
sudo install -d -m 0755 /usr/share/doc/pgtwin
sudo install -m 0644 README.md CHANGELOG.md QUICKSTART.md \
                     CHEATSHEET.md PROJECT_SUMMARY.md \
                     LICENSE VERSION \
                     /usr/share/doc/pgtwin/
```

## Testing Installation

After installation, verify the agent is properly installed:

```bash
# Test OCF agent presence
ocf-tester -n pgtwin -o help

# Or check manually
crm ra info ocf:heartbeat:pgtwin

# Test basic syntax
bash -n /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

## Uninstalling

### If installed via RPM:
```bash
sudo rpm -e pgtwin
```

### If installed via make:
```bash
sudo make uninstall
```

### Manual uninstall:
```bash
sudo rm /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo rm -rf /usr/share/doc/pgtwin
```

## Building for Distribution

### Creating a Release Tarball

```bash
# Ensure VERSION file is up to date
echo "1.6.0" > VERSION

# Create tarball
make tarball

# Result: pgtwin-1.6.0.tar.gz
```

### Updating Version

When releasing a new version:

1. Update VERSION file:
   ```bash
   echo "1.7.0" > VERSION
   ```

2. Update CHANGELOG.md with new version entry

3. Update version in pgtwin.spec:
   ```spec
   Version:        1.7.0
   ```

4. Update version string in pgtwin agent (line ~10):
   ```bash
   VERSION="1.7.0"
   ```

5. Create git tag:
   ```bash
   git tag -a v1.7.0 -m "Release version 1.7.0"
   git push origin v1.7.0
   ```

## Development

### Running Tests

```bash
# Basic syntax validation
make test

# Full test suite (if you have the test-pgtwin-ha-enhancements.sh script)
./test-pgtwin-ha-enhancements.sh
```

### Pre-commit Checklist

Before committing changes:
- [ ] Run `make test` - syntax validation
- [ ] Update VERSION file if needed
- [ ] Update CHANGELOG.md with changes
- [ ] Update README.md if features changed
- [ ] Test on actual cluster if possible
- [ ] Update pgtwin.spec %changelog

## Distribution-Specific Notes

### openSUSE Tumbleweed / SUSE Linux Enterprise

pgtwin has been tested on openSUSE Tumbleweed with:
- PostgreSQL 17.6
- Pacemaker 3.0.1+
- Corosync 3.1.8+

### RHEL / CentOS / Rocky Linux

Should work on RHEL-family distributions with:
- PostgreSQL 17+ (from official PostgreSQL repository)
- Pacemaker 2.1+ (RHEL 9) or 3.0+ (RHEL 10+)

### Debian / Ubuntu

For Debian/Ubuntu, you can convert the RPM to DEB:

```bash
# Install alien
sudo apt-get install alien

# Convert RPM to DEB
alien --to-deb pgtwin-1.6.0-1.noarch.rpm

# Install
sudo dpkg -i pgtwin_1.6.0-2_all.deb
```

Or install manually using the "Manual Installation" section above.

## Troubleshooting

### RPM build fails with "File not found"

Make sure all required files exist:
```bash
ls -l pgtwin README.md CHANGELOG.md QUICKSTART.md CHEATSHEET.md \
      PROJECT_SUMMARY.md LICENSE VERSION Makefile pgtwin.spec
```

### OCF agent not found after installation

Check the installation path:
```bash
# Pacemaker looks in /usr/lib/ocf/resource.d/heartbeat/
ls -l /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Some distributions use /usr/libexec instead
ls -l /usr/libexec/ocf/resource.d/heartbeat/pgtwin
```

### Permission denied when running agent

Ensure correct permissions:
```bash
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chown root:root /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

## Support

For issues with building or installing:
1. Check the [QUICKSTART.md](QUICKSTART.md) guide
2. Review [CHEATSHEET.md](CHEATSHEET.md) for common commands
3. Search existing issues on GitHub
4. Open a new issue with your system details

## License

pgtwin is licensed under GPL-2.0-or-later. See LICENSE file for details.
