# amber-webkit: one WebKitGTK build for the whole amber suite, against amber-gtk4's GTK 4.16,
# packaged to /usr/lib/amber-webkit, where the apps' RUNPATH points. What every bundle does is in
# house/bundle.mk, a copy of house-rules' scripts/binding/bundle.mk: this repository is public,
# and its runner has no house-rules. project.toml names the release, its options, the siblings
# and the system packages; README.md says why the bundle exists and docs/DECISIONS.md the
# choices below.

# Parallelism, set from a measurement on a 24-core, 62 GB desk: 24 compile jobs took the machine
# to 59 GB used with swap full, about 1.5 GB a job on top of the desk's own use; 12 jobs and two
# links at once (WebKit's own link pool, which reads WEBKIT_NINJA_LINK_MAX when cmake runs)
# leave more than 8 GB free. A smaller desk lowers them on the command line:
# `make build JOBS=6 LINK_JOBS=1`.
JOBS ?= 12
LINK_JOBS ?= 2

include house/bundle.mk

.PHONY: gtk-pc check-bundle-paths test hooks

# The GTK side. WebKit compiles against amber-gtk4's staged 4.16 headers, not Mint's 4.14: its
# accelerated backing store builds its frames with GdkMemoryTextureBuilder and damage regions
# only when GTK_CHECK_VERSION(4, 16, 0) holds at compile time (docs/DECISIONS.md, 3). At run time
# every object's RUNPATH reaches the amber-gtk4 bundle.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
# amber-gtk4's checkout is $(AMBER_ROOT)/amber-gtk4, or AMBER_GTK4_DIR where that is set (a
# worktree, in the gitignored local.mk).
GTK_STAGE ?= $(or $(AMBER_GTK4_DIR),$(AMBER_ROOT)/amber-gtk4)/build/stage
GTK_STAGE_PC = $(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig
GTK_PC = build/gtk-pc
RUNPATH = $(INSTALL_DIR):$(GTK_BUNDLE_DIR)
# The sonames Mint's 2.52 packages carry. An app built against either set of headers loads the
# bundle only while these stay the same; check-bundle-paths asserts them.
WEBKIT_SONAME = libwebkitgtk-6.0.so.4
JSC_SONAME = libjavascriptcoregtk-6.0.so.1

# amber-gtk4's .pc files name prefix=/usr, where the package installs; for the build they are
# copied with the prefix moved to its stage, so pkg-config hands cmake the 4.16 headers and the
# staged libgtk-4.so to link. Only the prefix line changes.
gtk-pc:
	@[ -n '$(AMBER_ROOT)' ] || { echo '$@: AMBER_ROOT is not set: it names the folder holding amber-gtk4'; exit 2; }
	@[ -e '$(GTK_STAGE_PC)/gtk4.pc' ] || { echo '$@: $(GTK_STAGE_PC)/gtk4.pc not found: build amber-gtk4 first (make -C $(or $(AMBER_GTK4_DIR),$(AMBER_ROOT)/amber-gtk4) build; make init-siblings clones it)'; exit 2; }
	@rm -rf $(GTK_PC) && mkdir -p $(GTK_PC)
	@for f in $(GTK_STAGE_PC)/*.pc; do \
		sed 's|^prefix=/usr$$|prefix=$(GTK_STAGE)/usr|' "$$f" > $(GTK_PC)/$${f##*/}; \
	done
	@v=$$(PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) pkg-config --modversion gtk4); \
	[ "$$v" = "$(GTK_BUNDLE_MIN)" ] || { echo "$@: amber-gtk4's stage is GTK $$v, this build expects $(GTK_BUNDLE_MIN)"; exit 1; }

# The release archive is checked twice before it is unpacked: against project.toml's sha256 when
# it is fetched, and here against its detached signature with the release key kept in
# packaging/upstream/ (webkitgtk.org/verifying.html, docs/DECISIONS.md, 7). An archive whose
# signature does not verify is deleted.
SIGNING_KEY = packaging/upstream/webkitgtk-signing-key.asc
SIGNED = build/signature-verified
$(SRC)/.unpacked: $(SIGNED)
$(SIGNED): $(TARBALL) $(SIGNING_KEY)
	curl -fL -o $(TARBALL).asc '$(SOURCE_URL).asc'
	@rm -f build/webkitgtk-keyring.gpg; \
	gpg --dearmor < $(SIGNING_KEY) > build/webkitgtk-keyring.gpg && \
	gpgv --keyring '$(CURDIR)/build/webkitgtk-keyring.gpg' $(TARBALL).asc $(TARBALL) || \
		{ echo "the signature does not verify: $(TARBALL) deleted"; rm -f $(TARBALL) $(TARBALL).asc; exit 1; }
	@touch $@

# The build sees the distro's tools only: a python3 or bwrap from mise or ~/.local would
# otherwise be what cmake finds, and the path it finds is compiled in. gtk4 comes from
# amber-gtk4's stage through gtk-pc's copies, order-only so that writing them again never
# configures the build again. The link pool is read when cmake runs.
$(OBJ)/build.ninja: | gtk-pc
$(OBJ)/build.ninja build: export PATH = /usr/bin:/bin
$(OBJ)/build.ninja: export PKG_CONFIG_PATH = $(CURDIR)/$(GTK_PC)
$(OBJ)/build.ninja: export WEBKIT_NINJA_LINK_MAX = $(LINK_JOBS)

# ccache, where the desk has it (`make init-workstation` installs it; init-packages and ci never
# do), as the compiler launcher; otherwise WK_USE_CCACHE=NO, since WebKit's cmake would pick it
# up on its own. The cache stays in ccache's own folder, so it survives `make clean` and serves
# every worktree; CCACHE_BASEDIR and CCACHE_NOHASHDIR make what it hashes independent of the
# checkout's path. The size is set here, not in the desk's ccache.conf: one build writes 0.4 GB
# of objects and 4.9 GB of precompiled headers, so 12 GB holds two. WebKit compiles with
# precompiled headers, which ccache caches only with the sloppiness below and CCACHE_PCH_EXTSUM.
CCACHE := $(shell command -v ccache 2>/dev/null)
CCACHE_MAXSIZE ?= 12G
ifneq ($(CCACHE),)
$(OBJ)/build.ninja: export CMAKE_C_COMPILER_LAUNCHER = $(CCACHE)
$(OBJ)/build.ninja: export CMAKE_CXX_COMPILER_LAUNCHER = $(CCACHE)
build: export CCACHE_MAXSIZE := $(CCACHE_MAXSIZE)
build: export CCACHE_BASEDIR = $(CURDIR)
build: export CCACHE_NOHASHDIR = true
build: export CCACHE_PCH_EXTSUM = true
build: export CCACHE_SLOPPINESS = pch_defines,time_macros,include_file_mtime,include_file_ctime
else
$(OBJ)/build.ninja: export WK_USE_CCACHE = NO
endif

# What cmake reads from the environment, written only when it changes, so the build is
# configured again when the link pool or ccache changes.
BUILD_ENV_FILE = build/build-env
$(OBJ)/build.ninja: $(BUILD_ENV_FILE)
$(BUILD_ENV_FILE): FORCE
	@mkdir -p build
	@echo 'LINK_JOBS=$(LINK_JOBS) CCACHE=$(CCACHE)' > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

# The checks of the bundle's own paths, which bundle.mk's check runs beside its own: every
# object's RUNPATH, Mint's sonames, the helpers and the directories compiled in, the GTK 4.16
# build. check-pc resolves the .pc files' gtk4 in amber-gtk4's stage, the GTK the library is
# built against.
check: check-bundle-paths
check-bundle-paths: build
	@scripts/check-bundle-paths $(BUNDLE) $(RUNPATH) $(WEBKIT_SONAME) $(JSC_SONAME)
check deb: export PKG_CONFIG_PATH = $(GTK_STAGE_PC)

# The smoke test: a small GTK program loads a local page in a WebView under xvfb, and checks that
# it and every WebKit process it spawned map WebKit from the bundle and GTK from amber-gtk4 and
# nothing else (tests/run-smoke says how the staged tree stands in for the installed one).
test: build gtk-pc ## load a page off screen against the staged bundle and check what every process maps
	@tests/run-smoke $(STAGE) $(GTK_PC)

# A shipped hook does nothing until core.hooksPath points at it; ccache is for a desk only.
init-workstation: hooks
	sudo apt-get install $(APT_FLAGS) --no-install-recommends ccache
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"
