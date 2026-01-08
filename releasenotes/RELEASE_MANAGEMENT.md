# Release Management Guide for pgtwin

This document provides instructions for Claude Code (and human maintainers) on how to create new releases of the pgtwin PostgreSQL HA resource agent.

## Repository Structure

```
/home/claude/postgresHA/
├── pgtwin                      # Main development version
├── github/                     # Distribution directory (for GitHub release)
│   ├── pgtwin                  # Production-ready agent
│   ├── VERSION                 # Version number file
│   ├── QUICKSTART.md           # Setup guide
│   ├── README.md               # Main documentation
│   ├── RELEASE_v*.md           # Release notes
│   └── ...                     # Other docs
├── CLAUDE.md                   # Project guidance for Claude Code
├── RELEASE_v*.md               # Release notes (main directory)
└── test-pgsql-ha-enhancements.sh  # Test suite
```

**IMPORTANT**: The `github/` directory contains the distribution-ready version of pgtwin for publishing.

---

## Release Checklist

### Pre-Release Tasks

- [ ] All changes tested and verified
- [ ] Test suite passes: `./test-pgsql-ha-enhancements.sh` (if applicable)
- [ ] Shell syntax validated: `bash -n pgtwin`
- [ ] Documentation updated (README.md, QUICKSTART.md, etc.)
- [ ] CHANGELOG updated (if maintained)

### Version Number Update

Determine the new version number based on semantic versioning:
- **Major** (x.0.0): Breaking changes, major features
- **Minor** (1.x.0): New features, backward compatible
- **Patch** (1.6.x): Bug fixes, documentation improvements

### Files to Update for Each Release

#### 1. Main Agent (`pgtwin`)

Update version number and date in header:
```bash
# Line 4: Version number
# Version: 1.6.3

# Line 5: Release date
# Release Date: 2025-11-05
```

Update OCF metadata (around line 90):
```bash
# Resource agent name should be "pgtwin"
<resource-agent name="pgtwin" version="1.6">
```

#### 2. GitHub Distribution (`github/pgtwin`)

**CRITICAL**: Always copy the updated main agent to the github directory:
```bash
cp pgtwin github/pgtwin
```

Verify the copy:
```bash
head -5 github/pgtwin | grep Version
```

#### 3. Version File (`github/VERSION`)

Update the version number:
```bash
echo "1.6.3" > github/VERSION
```

Verify:
```bash
cat github/VERSION
```

#### 4. Release Notes

Create release notes in **both** locations:
- `/home/claude/postgresHA/RELEASE_v{VERSION}.md`
- `/home/claude/postgresHA/github/RELEASE_v{VERSION}.md`

**Template Structure**:
```markdown
# Release Notes: pgtwin v{VERSION}

**Release Date**: YYYY-MM-DD
**Type**: Bug Fix / Feature / Documentation
**Status**: Brief status

## Overview
Executive summary of changes

## Changes
### Bug Fixes / Features / Documentation
Detailed list of changes

## Upgrade Instructions
How to upgrade from previous version

## Files Modified
Table of modified files

## Verification
How to verify the release

## Support
Links to support resources
```

#### 5. CLAUDE.md

Update project metadata:
- Current version number (line 9)
- Update code location line numbers if major changes
- Add new version to version history

#### 6. QUICKSTART.md (github directory)

If installation or setup changes, update:
- Installation commands
- Version references
- Configuration examples

---

## Release Process

### Step-by-Step Instructions

#### 1. Update Version Numbers

```bash
# Main agent
vim pgtwin  # Update header (lines 4-5)

# GitHub version file
echo "X.Y.Z" > github/VERSION
```

#### 2. Copy Agent to GitHub Directory

```bash
# ALWAYS copy after making changes to pgtwin
cp pgtwin github/pgtwin

# Verify
diff pgtwin github/pgtwin  # Should show no differences
```

#### 3. Create Release Notes

```bash
# Main directory
vim RELEASE_vX.Y.Z.md

# GitHub directory (distribution)
vim github/RELEASE_vX.Y.Z.md
```

#### 4. Update Documentation

```bash
# Update CLAUDE.md
vim CLAUDE.md

# Update github documentation if needed
vim github/QUICKSTART.md
vim github/README.md
```

#### 5. Validate Changes

```bash
# Syntax check
bash -n pgtwin
bash -n github/pgtwin

# Version verification
head -5 pgtwin | grep Version
head -5 github/pgtwin | grep Version
cat github/VERSION

# All should show the same version
```

#### 6. Commit Changes

```bash
# Stage files
git add pgtwin github/ RELEASE_vX.Y.Z.md CLAUDE.md

# Create commit with detailed message
git commit -m "Release vX.Y.Z: Brief Description

Detailed description of changes

### Changes
- Change 1
- Change 2

### Files Modified
- pgtwin: Description
- github/pgtwin: Synced with main
- github/VERSION: X.Y.Z
- RELEASE_vX.Y.Z.md: Release notes

🤖 Generated with Claude Code (https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

#### 7. Create Git Tag (Optional)

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
```

---

## Common Release Scenarios

### Patch Release (Bug Fix)

Example: 1.6.3 → 1.6.4

1. Fix bugs in `pgtwin`
2. Update version in header (1.6.4)
3. Copy to `github/pgtwin`
4. Update `github/VERSION` to 1.6.4
5. Create `RELEASE_v1.6.4.md` (both locations)
6. Update CLAUDE.md version
7. Commit and tag

### Minor Release (New Features)

Example: 1.6.3 → 1.7.0

1. Implement features in `pgtwin`
2. Update version in header (1.7.0)
3. Update OCF metadata version if needed
4. Copy to `github/pgtwin`
5. Update `github/VERSION` to 1.7.0
6. Update documentation (QUICKSTART.md, README.md)
7. Create comprehensive release notes
8. Update CLAUDE.md (version + line numbers)
9. Commit and tag

### Documentation-Only Release

Example: 1.6.2 (documentation improvements)

1. Update documentation in `github/` directory
2. Update `github/VERSION` (increment patch)
3. Create minimal release notes
4. Update CLAUDE.md version
5. Commit (no need to copy pgtwin if unchanged)

---

## Critical Don'ts

❌ **NEVER** release without copying to `github/pgtwin`
❌ **NEVER** modify `github/pgtwin` directly (always copy from main)
❌ **NEVER** forget to update `github/VERSION`
❌ **NEVER** skip release notes creation
❌ **NEVER** commit without verifying version numbers match

---

## Quick Release Commands

```bash
# Quick release workflow (assuming changes already made)
VERSION="1.6.3"
DATE="2025-11-05"

# Update versions
sed -i "s/^# Version: .*/# Version: $VERSION/" pgtwin
sed -i "s/^# Release Date: .*/# Release Date: $DATE/" pgtwin
echo "$VERSION" > github/VERSION

# Copy to github
cp pgtwin github/pgtwin

# Verify
bash -n pgtwin && bash -n github/pgtwin && echo "✓ Syntax OK"
head -5 pgtwin | grep Version
head -5 github/pgtwin | grep Version
cat github/VERSION

# Create release notes (manual)
vim RELEASE_v${VERSION}.md
vim github/RELEASE_v${VERSION}.md

# Commit
git add pgtwin github/ RELEASE_v${VERSION}.md CLAUDE.md
git commit -m "Release v${VERSION}: <description>"
git tag -a v${VERSION} -m "Release v${VERSION}"
```

---

## Verification Checklist

After completing release process:

- [ ] `pgtwin` header shows correct version
- [ ] `github/pgtwin` header shows correct version
- [ ] `github/VERSION` file shows correct version
- [ ] Both agents have identical content: `diff pgtwin github/pgtwin`
- [ ] Release notes exist in both locations
- [ ] CLAUDE.md updated with new version
- [ ] All files committed to git
- [ ] Git tag created (if desired)
- [ ] Syntax validation passes

---

## Distribution

The `github/` directory is designed for distribution:

1. **GitHub Releases**: Upload contents of `github/` directory
2. **Package Managers**: Use `github/pgtwin` as source
3. **Documentation**: Link to files in `github/` for users

---

## Rollback Procedure

If a release has issues:

1. Identify last good version: `git log --oneline`
2. Revert to previous version: `git checkout vX.Y.Z -- pgtwin github/`
3. Update VERSION files to previous version
4. Create rollback commit
5. Communicate rollback to users

---

## Support

For questions about release management:
- Check recent commits: `git log --oneline --all --graph`
- Review previous release: `cat RELEASE_v1.6.3.md`
- Consult CLAUDE.md for project structure

---

**Last Updated**: 2025-11-05 (v1.6.3)
**Maintained By**: Claude Code + Human Maintainers
