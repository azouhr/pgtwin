# Makefile for pgtwin
# Simplifies installation, testing, and RPM building

NAME = pgtwin
VERSION = $(shell cat VERSION)
DESTDIR ?=
PREFIX ?= /usr
LIBDIR = $(PREFIX)/lib
DOCDIR = $(PREFIX)/share/doc/$(NAME)
OCF_DIR = $(LIBDIR)/ocf/resource.d/heartbeat

# Installation paths
INSTALL_AGENT = $(DESTDIR)$(OCF_DIR)/$(NAME)
INSTALL_DOCS = $(DESTDIR)$(DOCDIR)

.PHONY: all install uninstall clean test rpm tarball help

all: help

help:
	@echo "pgtwin Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  install      - Install pgtwin OCF agent to system"
	@echo "  uninstall    - Remove pgtwin OCF agent from system"
	@echo "  test         - Run basic syntax tests"
	@echo "  tarball      - Create source tarball for RPM building"
	@echo "  rpm          - Build RPM package (requires rpmbuild)"
	@echo "  clean        - Remove build artifacts"
	@echo ""
	@echo "Installation variables:"
	@echo "  DESTDIR=$(DESTDIR)"
	@echo "  PREFIX=$(PREFIX)"
	@echo "  OCF_DIR=$(OCF_DIR)"
	@echo ""
	@echo "Example usage:"
	@echo "  make install              # Install to /usr/lib/ocf/..."
	@echo "  make install PREFIX=/opt  # Install to /opt/lib/ocf/..."
	@echo "  make rpm                  # Build RPM package"

install:
	@echo "Installing pgtwin v$(VERSION)..."
	install -d -m 0755 $(DESTDIR)$(OCF_DIR)
	install -m 0755 $(NAME) $(DESTDIR)$(OCF_DIR)/$(NAME)
	install -d -m 0755 $(INSTALL_DOCS)
	install -m 0644 README.md CHANGELOG.md QUICKSTART.md CHEATSHEET.md PROJECT_SUMMARY.md LICENSE VERSION $(INSTALL_DOCS)/
	@echo "Installation complete."
	@echo "  Agent: $(INSTALL_AGENT)"
	@echo "  Docs:  $(INSTALL_DOCS)"

uninstall:
	@echo "Uninstalling pgtwin..."
	rm -f $(INSTALL_AGENT)
	rm -rf $(INSTALL_DOCS)
	@echo "Uninstallation complete."

test:
	@echo "Running syntax tests..."
	bash -n $(NAME)
	@echo "Checking for required functions..."
	@grep -q "pgsql_start()" $(NAME) || (echo "ERROR: Missing pgsql_start function"; exit 1)
	@grep -q "pgsql_stop()" $(NAME) || (echo "ERROR: Missing pgsql_stop function"; exit 1)
	@grep -q "pgsql_monitor()" $(NAME) || (echo "ERROR: Missing pgsql_monitor function"; exit 1)
	@grep -q "pgsql_promote()" $(NAME) || (echo "ERROR: Missing pgsql_promote function"; exit 1)
	@grep -q "pgsql_demote()" $(NAME) || (echo "ERROR: Missing pgsql_demote function"; exit 1)
	@echo "All tests passed."

tarball:
	@echo "Creating source tarball..."
	mkdir -p $(NAME)-$(VERSION)
	cp $(NAME) README.md CHANGELOG.md QUICKSTART.md CHEATSHEET.md PROJECT_SUMMARY.md LICENSE VERSION Makefile $(NAME).spec $(NAME)-$(VERSION)/
	tar czf $(NAME)-$(VERSION).tar.gz $(NAME)-$(VERSION)/
	rm -rf $(NAME)-$(VERSION)
	@echo "Created: $(NAME)-$(VERSION).tar.gz"

rpm: tarball
	@echo "Building RPM package..."
	mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	cp $(NAME)-$(VERSION).tar.gz ~/rpmbuild/SOURCES/
	cp $(NAME).spec ~/rpmbuild/SPECS/
	rpmbuild -ba ~/rpmbuild/SPECS/$(NAME).spec
	@echo "RPM build complete. Packages are in ~/rpmbuild/RPMS/"

clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(NAME)-$(VERSION) $(NAME)-$(VERSION).tar.gz
	rm -rf ~/rpmbuild/BUILD/$(NAME)-*
	@echo "Clean complete."

# Development helpers
version:
	@echo "pgtwin version $(VERSION)"

check-version:
	@echo "Checking version consistency..."
	@grep -q "VERSION=\"$(VERSION)\"" $(NAME) || (echo "WARNING: Version mismatch in $(NAME)"; exit 1)
	@echo "Version $(VERSION) is consistent."
