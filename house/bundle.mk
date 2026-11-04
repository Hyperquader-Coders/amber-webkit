# --- bundle.mk: house-rules scripts/binding/bundle.mk, the same in every bundle of an upstream library ---
# What every bundle does, for a project.toml whose kind is "bundle": fetch an upstream release and
# check it against its sum, apply the suite's patches, configure and build it with meson or cmake
# into /usr/lib/<name>, off the linker's and the loader's path, stage and strip it, check the
# staged bundle, and package it as <name> and, where it has headers or .pc files, <name>-dev. A
# program reaches it only through a RUNPATH naming /usr/lib/<name>. The bundle's Makefile is the
# bootstrap, then what is its own: a signature beside the sum, a smoke test of the library, a
# check of its own (`[project] steps` names it, or `lint: <check>` adds it to lint).
#
# [bundle], each key a fact:
#
#   version       the upstream release; the packages are version-1 (PROJECT_TOML K8) (required)
#   source        the release archive's URL (required)
#   sha256        the archive's SHA-256, as upstream publishes it (required)
#   commit        the commit the archive must name (git get-tar-commit-id), for an archive GitHub
#                 makes from a tag (default none)
#   build-system  meson or cmake (required)
#   options       the configure options as name=value words, each given as -D (default none)
#   build-flags   dpkg-buildflags' DEB_BUILD_MAINT_OPTIONS (default hardening=+all)
#
# What is code is a file at a fixed path: patches/*.patch, applied in order with -p1; and the
# checks, each run where it is there: scripts/after-stage <stage> <install dir> (fix-ups to the
# staged tree), scripts/check-no-cascade <shared object>, scripts/check-no-buildpaths <folder>,
# scripts/check-pc <pkgconfig> <install dir>. A check whose arguments are the bundle's own, such as
# the RUNPATH and sonames check-bundle-paths holds it to, is the bundle's target (`check: <it>`).
#
# A bundle that links another of the suite's bundles (amber-libgit2 links amber-llhttp's llhttp)
# sets SUITE_BUNDLES in its Makefile: that bundle's staged folder, <its checkout>/build/stage/usr/
# lib/<its name>. check-no-cascade allows its libraries there, and dpkg-shlibdeps finds them
# there, where no package is installed; packaging/debian/shlibs.local maps each to its package.

BUNDLE_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
include $(BUNDLE_MK_DIR)project.mk
$(if $(filter bundle,$(KIND)),,$(error bundle.mk is for a project.toml whose kind is bundle, not '$(KIND)'))

VERSION      := $(call setting,version)
SOURCE_URL   := $(call setting,source)
SOURCE_SHA   := $(call setting,sha256)
SOURCE_COMMIT := $(call setting,commit)
BUILD_SYSTEM := $(call setting,build-system)
OPTIONS      := $(call setting,options)
$(foreach k,version source sha256 build-system,$(if $(call setting,$(k)),,$(error project.toml's [bundle] names no $(k))))
$(if $(filter meson cmake,$(BUILD_SYSTEM)),,$(error project.toml's [bundle] build-system is meson or cmake, not '$(BUILD_SYSTEM)'))

include $(BUNDLE_MK_DIR)house.mk

# Configured with /usr and staged through DESTDIR: a library compiles its prefix in, so a prefix
# in the checkout would ship the builder's home. The programs' RUNPATH names INSTALL_DIR, so it is
# part of the contract with them.
INSTALL_DIR := /usr/lib/$(NAME)
TARBALL     := build/$(notdir $(SOURCE_URL))
SRC         := build/src
OBJ         := build/obj
STAGE       := build/stage
BUNDLE      := $(STAGE)$(INSTALL_DIR)
CONFIG      := build/config
JOBS        ?= $(shell nproc)

# The distro's hardening flags, all of them (full RELRO and immediate binding as well), and the
# checkout's path mapped out of __FILE__ and the debug strings. [bundle] build-flags is
# dpkg-buildflags' DEB_BUILD_MAINT_OPTIONS (default hardening=+all), so a bundle too big for an
# LTO link says "hardening=+all optimize=-lto". No -g: the stage is stripped.
MAINT_OPTIONS := $(or $(call setting,build-flags),hardening=+all)
BUILDFLAGS = DEB_BUILD_MAINT_OPTIONS='$(MAINT_OPTIONS)' DEB_CFLAGS_MAINT_STRIP=-g DEB_CXXFLAGS_MAINT_STRIP=-g dpkg-buildflags --get
BUILD_FLAGS_ENV = env CPPFLAGS="$$($(BUILDFLAGS) CPPFLAGS)" LDFLAGS="$$($(BUILDFLAGS) LDFLAGS)" \
	CFLAGS="$$($(BUILDFLAGS) CFLAGS) -ffile-prefix-map=$(CURDIR)/=" \
	CXXFLAGS="$$($(BUILDFLAGS) CXXFLAGS) -ffile-prefix-map=$(CURDIR)/="
ifeq ($(BUILD_SYSTEM),meson)
# meson's c_link_args and cpp_link_args take the place of LDFLAGS, so where a bundle sets one the
# hardening linker flags go into it as well.
HARDENING_LDFLAGS := $(shell $(BUILDFLAGS) LDFLAGS 2>/dev/null)
MESON_OPTIONS = $(foreach o,$(OPTIONS),$(if $(filter c_link_args=% cpp_link_args=%,$(o)),'-D$(o) $(HARDENING_LDFLAGS)',-D$(o)))
CONFIGURE = meson setup $(OBJ) $(SRC) --prefix=/usr --libdir=lib/$(NAME) --includedir=lib/$(NAME)/include \
	--buildtype=release $(MESON_OPTIONS)
else
CONFIGURE = cmake -S $(SRC) -B $(OBJ) -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_INSTALL_LIBDIR=lib/$(NAME) -DCMAKE_INSTALL_INCLUDEDIR=lib/$(NAME)/include $(addprefix -D,$(OPTIONS))
endif

# The two packages; <name>-dev only where the stage has what a build against the bundle reads.
DEB      = dist/$(NAME)_$(VERSION)-1_amd64.deb
DEV_DEB  = dist/$(NAME)-dev_$(VERSION)-1_amd64.deb
HAS_DEV  = $(wildcard $(BUNDLE)/include $(BUNDLE)/pkgconfig)
DEBS     = $(DEB) $(if $(HAS_DEV),$(DEV_DEB))
PACKAGES = $(NAME) $(if $(HAS_DEV),$(NAME)-dev)

# $(call elf_files,<folder>): every ELF file under it, one a line: the shared objects and the
# programs beside them (a loader in libexec), which strip and dpkg-shlibdeps both read.
elf_files = find $(1) -type f -exec sh -c 'for f; do [ "$$(head -c4 "$$f" | od -An -c | tr -d " \n")" = "177ELF" ] && echo "$$f"; done; true' sh {} +

# $(call run_if,<script> <args>): a check of the repository's own, where it is there.
run_if = @if [ -x scripts/$(firstword $(1)) ]; then scripts/$(1); fi

# A target whose recipe fails or is interrupted is removed, so it is never taken as made.
.DELETE_ON_ERROR:
.PHONY: build check deb deb-path deb-install deb-remove check-lintian clean push lint FORCE

##@ Build
# A fetched archive that does not match its sum, or names another commit, is deleted, so a wrong
# version fails here and not after the build.
$(TARBALL):
	@mkdir -p build
	curl -fL -o $@.part '$(SOURCE_URL)'
	@echo '$(SOURCE_SHA)  $@.part' | sha256sum -c - || { rm -f $@.part; exit 1; }
	@# GitHub's archive of a tag is a .tar.gz with the commit in its first header. git reads it
	@# from a file: from a pipe, its one read can come back short and find no commit.
	@if [ -n '$(SOURCE_COMMIT)' ]; then gzip -dc $@.part 2>/dev/null | head -c 1024 > $@.head; \
		c=$$(git get-tar-commit-id < $@.head); rm -f $@.head; \
		[ "$$c" = '$(SOURCE_COMMIT)' ] || { echo "the archive names commit '$$c', not $(SOURCE_COMMIT): deleted"; rm -f $@.part; exit 1; }; fi
	mv $@.part $@

# The source is unpacked again when the archive or a patch changes. A patch that stops applying
# stops the build, rather than shipping upstream's behaviour unannounced.
$(SRC)/.unpacked: $(TARBALL) $(wildcard patches/*.patch)
	rm -rf $(SRC) $(OBJ)
	mkdir -p $(SRC)
	tar xf $(TARBALL) -C $(SRC) --strip-components=1
	@for p in $(wildcard patches/*.patch); do echo "applying $$p"; patch -p1 -N -d $(SRC) --no-backup-if-mismatch --input='$(CURDIR)'/$$p || exit 1; done
	@touch $@

# The configuration as one line, rewritten only when it changes, so the build is configured again
# only then.
$(CONFIG): FORCE
	@mkdir -p build
	@echo '$(CONFIGURE)' > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

$(OBJ)/build.ninja: $(SRC)/.unpacked $(CONFIG)
	rm -rf $(OBJ)
	$(BUILD_FLAGS_ENV) $(CONFIGURE) > build/configure.log 2>&1 || { tail -40 build/configure.log; exit 1; }
	@touch $@

build: $(OBJ)/build.ninja ## fetch, check, patch, configure and build the library, staged and stripped in build/stage
	@echo "building with $(JOBS) jobs; the log is build/build.log"
	ninja -C $(OBJ) -j $(JOBS) > build/build.log 2>&1 || { grep -B2 -A20 -m3 'FAILED:' build/build.log || tail -60 build/build.log; exit 1; }
	rm -rf $(STAGE)
	DESTDIR='$(CURDIR)/$(STAGE)' ninja -C $(OBJ) install > build/install.log 2>&1 || { tail -40 build/install.log; exit 1; }
	$(call run_if,after-stage $(STAGE) $(INSTALL_DIR))
	$(call elf_files,$(BUNDLE)) | xargs -r -d '\n' strip --strip-unneeded --remove-section=.comment --remove-section=.note

clean: ## remove build/ and dist/, the library's build with them
	rm -rf build dist

push: ## push the branch
	git push "$(REMOTE)" "$(BRANCH)"

##@ Verify
# What makes a bundle safe to ship: it resolves against the distro's stack and pulls nothing
# newer in, it carries no path of the machine that built it, and its .pc files point inside it.
SHARED_OBJECTS = $(shell find $(BUNDLE) -maxdepth 1 -type f -name '*.so.*' 2>/dev/null)
check: build ## the staged bundle: no newer stack pulled in, no build paths, its .pc files its own
	@for so in $(SHARED_OBJECTS); do $(if $(wildcard scripts/check-no-cascade),scripts/check-no-cascade "$$so" $(SUITE_BUNDLES) || exit 1;) :; done
	$(call run_if,check-no-buildpaths $(BUNDLE))
	$(if $(wildcard $(BUNDLE)/pkgconfig),$(call run_if,check-pc $(BUNDLE)/pkgconfig $(INSTALL_DIR)))

lint: ## house-rules' narration and host checks, shellcheck, the changelog at the version
	$(call house_check,check-narration)
	$(call house_check,check-example-hosts $(CURDIR))
	$(if $(wildcard MoSCoW.md),$(call house_check,moscow $(CURDIR)))
	@if command -v shellcheck >/dev/null; then \
		$(SH_SOURCES) | xargs -r -d '\n' shellcheck --severity=warning && echo 'shellcheck OK'; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo 'shellcheck is not installed on this runner; it is in project.toml'; exit 1; \
	else echo 'shellcheck not installed: skipping (make init-packages installs it)'; fi
	@v=$$(dpkg-parsechangelog -l packaging/debian/changelog -S Version); [ "$$v" = '$(VERSION)-1' ] || \
		{ echo "packaging/debian/changelog is at $$v, not $(VERSION)-1"; exit 1; }
	@echo 'packaging/debian/changelog: $(VERSION)-1'

##@ Package
# One staging, both packages: <name> takes the shared objects and the modules beside them; -dev
# the headers, the .pc and cmake files, the static archives and the unversioned .so links. The
# control file is packaging/debian/control, with a stanza for each (K13); dpkg-shlibdeps and
# dpkg-gencontrol fill in the Depends and the Installed-Size.
deb: check ## package the bundle into dist/: <name>, and <name>-dev where it has headers
	rm -rf build/deb build/debwork
	mkdir -p build/deb/$(NAME)$(INSTALL_DIR) build/deb/$(NAME)-dev$(INSTALL_DIR)
	cp -a $(BUNDLE)/. build/deb/$(NAME)$(INSTALL_DIR)/
	@# A bundle's own data folder (WebKit's translations), where the build put it.
	[ ! -d $(STAGE)/usr/share/$(NAME) ] || { mkdir -p build/deb/$(NAME)/usr/share/$(NAME) && cp -a $(STAGE)/usr/share/$(NAME)/. build/deb/$(NAME)/usr/share/$(NAME)/; }
	cd build/deb/$(NAME)$(INSTALL_DIR) && dev='$(CURDIR)/build/deb/$(NAME)-dev$(INSTALL_DIR)' && \
		for d in include pkgconfig cmake; do [ ! -e $$d ] || mv $$d "$$dev/"; done && \
		find . -maxdepth 1 \( -name '*.so' -o -name '*.a' \) -exec mv -t "$$dev" {} +
	@# A shared object is not executable (lintian), however the build installed it.
	find build/deb -type f -name '*.so*' -exec chmod 644 {} +
	$(call run_if,check-no-buildpaths build/deb)
	$(if $(HAS_DEV),$(call run_if,check-pc build/deb/$(NAME)-dev$(INSTALL_DIR)/pkgconfig $(INSTALL_DIR)))
	@set -e; for p in $(PACKAGES); do root=build/deb/$$p; \
		o=packaging/lintian-overrides; [ ! -d $$o ] || o=$$o/$$p; \
		[ ! -f $$o ] || install -D -m644 $$o $$root/usr/share/lintian/overrides/$$p; \
		install -D -m644 packaging/debian/copyright $$root/usr/share/doc/$$p/copyright; \
		gzip -9n < packaging/debian/changelog > $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		chmod 644 $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		find $$root -type d -exec chmod 755 {} +; \
		mkdir -p $$root/DEBIAN; \
		(cd $$root && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs -r md5sum > DEBIAN/md5sums); \
	done
	@# The bundle is not on the loader's path, so installing it changes what no other program loads.
	mkdir -p build/debwork/debian
	cp packaging/debian/control packaging/debian/changelog build/debwork/debian/
	@# shlibs.local maps a library the bundle loads from the suite to the suite's package
	@# (libgtk-4 1 amber-gtk4 (>= 4.16.13)), so Depends never names the distro's twin.
	[ ! -f packaging/debian/shlibs.local ] || cp packaging/debian/shlibs.local build/debwork/debian/
	@# -l: a module the bundle ships (GTK's print backends) links the bundle's own library, which
	@# is found there, not on a machine that happens to have the distro's twin.
	cd build/debwork && dpkg-shlibdeps --ignore-missing-info -l../deb/$(NAME)$(INSTALL_DIR) $(addprefix -l,$(SUITE_BUNDLES)) -Tdebian/substvars \
		$$($(call elf_files,../deb/$(NAME)))
	echo 'misc:Depends=' >> build/debwork/debian/substvars
	cd build/debwork && for p in $(PACKAGES); do dpkg-gencontrol -p$$p -v$(VERSION)-1 -P../deb/$$p -Tdebian/substvars || exit 1; done
	@# A folder made under a setgid one (a runner's volume) is setgid too, which chmod 755 keeps on
	@# a folder, and dpkg-deb refuses it.
	find build/deb -type d -exec chmod g-s {} +
	mkdir -p dist
	dpkg-deb --build --root-owner-group build/deb/$(NAME) $(DEB)
	$(if $(HAS_DEV),dpkg-deb --build --root-owner-group build/deb/$(NAME)-dev $(DEV_DEB))

deb-path: ## print the packages' absolute paths, one a line
	@for d in $(DEBS); do echo "$(CURDIR)/$$d"; done

# --allow-downgrades: once the packages are in the archive, apt reads installing a local build of
# the same version as a downgrade and refuses it.
deb-install: deb ## build the packages and install them (sudo)
	sudo apt install --reinstall --allow-downgrades $(addprefix ./,$(DEBS))

deb-remove: ## remove the installed packages (sudo)
	sudo apt remove $(PACKAGES)

check-lintian: deb ## lintian on the packages (needs the build)
	@if command -v lintian >/dev/null; then \
		lintian --tag-display-limit 0 -L '>=pedantic' --fail-on error,warning $(DEBS) && echo 'lintian OK'; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo 'lintian is not installed on this runner; it is in project.toml'; exit 1; \
	else echo 'lintian not installed: skipping (make init-packages installs it)'; fi
