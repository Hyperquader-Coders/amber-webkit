# amber-webkit: one WebKitGTK build for the whole amber suite.
#
# `make build` builds it against amber-gtk4's GTK 4.16, `make deb` packages it to
# /usr/lib/amber-webkit, and the apps point their RUNPATH there. See README.md for why it
# exists and docs/DECISIONS.md for the choices below.
# check-packaging: upstream (WebKitGTK 2.54.1, rebuilt for the suite)
VERSION = 2.54.1
# The package revision, bumped when the packaging changes but the WebKit version does not.
REVISION = 1
DEB = dist/amber-webkit_$(VERSION)-$(REVISION)_amd64.deb
DEV_DEB = dist/amber-webkit-dev_$(VERSION)-$(REVISION)_amd64.deb
DEBS = $(DEB) $(DEV_DEB)
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-webkit
# The siblings are found through the roots' variables, which mise sets on a development
# machine. AMBER_ROOT is the Amber tree, holding amber-gtk4 (siblings.txt). HOUSE_ROOT is the
# folder holding house-rules, whose check-narration and check-example-hosts `check-sources`
# runs where it is there; house-rules is private, so it is not in siblings.txt, and a clone
# outside the house and the public runner go without those two checks, saying so.
HOUSE_SCRIPTS = $(HOUSE_ROOT)/house-rules/scripts

# $(call require,VARIABLE,path,sibling,what to do): fail, naming the variable, when it is unset
# or the sibling's file is not there.
require = @test -n '$($(1))' || { \
	    echo '$@: $(1) is not set: it names the folder holding $(3) (mise sets it on a development machine)'; \
	    exit 2; }; \
	test -e '$(2)' || { \
	    echo '$@: $(2) not found ($(1)=$($(1))): $(4)'; \
	    exit 2; }

# Where the build lands, and where the debs install it. Apps hardcode INSTALL_DIR in their
# release RUNPATH, so it is part of the contract with them.
#
# Configured with /usr and staged through DESTDIR: WebKit compiles the helper-process
# directory, the injected-bundle directory and the locale directory into the shipped .so,
# so a build-tree prefix would ship the builder's home directory. libdir and libexecdir are
# both lib/amber-webkit, which puts the helpers in /usr/lib/amber-webkit/webkitgtk-6.0;
# the headers and .pc files go under the same directory so they never meet Mint's
# libwebkitgtk-6.0-dev. The translations go in their own directory under /usr/share, since
# Mint's libwebkitgtk-6.0-4 owns /usr/share/locale/*/LC_MESSAGES/WebKitGTK-6.0.mo.
INSTALL_DIR = /usr/lib/amber-webkit
LOCALE_DIR = /usr/share/amber-webkit/locale
STAGE = build/webkit/stage
BUNDLE = $(STAGE)$(INSTALL_DIR)
SRC = build/webkit/src
OBJ = build/webkit/_build
# Written when make check passes against the staged bundle.
CHECKED = build/checked
# The sonames Mint's 2.52 packages carry. An app built against either set of headers loads
# the bundle only while these stay the same; `make check` asserts them.
WEBKIT_SONAME = libwebkitgtk-6.0.so.4
JSC_SONAME = libjavascriptcoregtk-6.0.so.1

# The GTK side. WebKit compiles against amber-gtk4's staged 4.16 headers, not Mint's 4.14:
# its accelerated backing store builds its frames with GdkMemoryTextureBuilder and damage
# regions only when GTK_CHECK_VERSION(4, 16, 0) holds at compile time (docs/DECISIONS.md, 3).
# At run time every object's RUNPATH reaches the amber-gtk4 bundle.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
GTK_STAGE ?= $(AMBER_ROOT)/amber-gtk4/build/gtk/stage
GTK_PC = build/gtk-pc
RUNPATH = $(INSTALL_DIR):$(GTK_BUNDLE_DIR)

# The release tarball, checked twice before it is unpacked: against the sha256 pinned here
# (the .sums file webkitgtk.org publishes beside it), and against its detached signature with
# the release key kept in packaging/upstream/ (webkitgtk.org/verifying.html). A fetched archive
# that fails either is deleted. Lives under build/, not /tmp: /tmp is shared and predictable.
TARBALL = build/webkitgtk-$(VERSION).tar.xz
TARBALL_SHA256 = ea0bbb02dbdbc596874a4e7ad35b66645b3e0a232bd0e4081de5ed92eb0a397d
TARBALL_URL = https://webkitgtk.org/releases/webkitgtk-$(VERSION).tar.xz
SIGNING_KEY = packaging/upstream/webkitgtk-signing-key.asc

# Parallelism, set from a measurement on a 24-core, 62 GB desk: 24 compile jobs took the
# machine to 59 GB used with swap full, about 1.5 GB a job on top of the desk's own use;
# 12 jobs and two links at once (WebKit's own link pool, which reads WEBKIT_NINJA_LINK_MAX when
# cmake runs) leave more than 8 GB free. A smaller desk lowers them on the command line:
# `make build JOBS=6 LINK_JOBS=1`. LINK_JOBS is a configure setting, so changing it
# reconfigures.
JOBS ?= 12
LINK_JOBS ?= 2

# ccache, where the desk has it (`make init-workstation` installs it; init-packages and ci
# never do). The build names it as the compiler launcher when `command -v ccache` finds it, and
# otherwise sets WK_USE_CCACHE=NO, since WebKit's cmake would pick it up on its own. The cache
# stays in ccache's own folder (~/.cache/ccache), so it survives `make clean` and serves every
# worktree; CCACHE_BASEDIR and CCACHE_NOHASHDIR make what it hashes independent of the
# checkout's path. CCACHE_MAXSIZE is set here, in the build's environment and not in the desk's
# ccache.conf: one full build writes 0.4 GB of objects and 4.9 GB of precompiled headers, so
# 12 GB holds two builds. WebKit compiles with precompiled headers, which ccache caches only
# with the sloppiness below and CCACHE_PCH_EXTSUM.
WORKSTATION_DEPS := ccache
CCACHE := $(shell command -v ccache 2>/dev/null)
CCACHE_MAXSIZE ?= 12G
CCACHE_FLAGS = $(if $(CCACHE),-DCMAKE_C_COMPILER_LAUNCHER=$(CCACHE) -DCMAKE_CXX_COMPILER_LAUNCHER=$(CCACHE))
CCACHE_ENV = $(if $(CCACHE),CCACHE_MAXSIZE=$(CCACHE_MAXSIZE) CCACHE_BASEDIR=$(CURDIR) CCACHE_NOHASHDIR=true \
	CCACHE_PCH_EXTSUM=true CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime,WK_USE_CCACHE=NO)

# fmt lays out the shell scripts; the one C file, tests/smoke.c, is laid out by hand.

.PHONY: help setup init-packages init-modules init-workstation build built gtk-pc check test ci deb deb-path deb-install deb-remove clean push force-push lint check-sources hooks check-no-agent-files

# The system packages a build, the test and the checks need, in one list: a development machine
# installs them with `make init-packages`. cmake, ninja, gcc-14, perl, ruby, python3 and gperf
# build WebKit; the -dev packages are its libraries; bubblewrap and xdg-dbus-proxy are the
# sandbox, whose paths are compiled in; gpgv checks the tarball; dpkg-dev (dpkg-shlibdeps),
# binutils (strip, readelf), lintian, shellcheck and shfmt are for packaging and lint; xvfb and
# xauth run the smoke test off screen. libwebkitgtk-6.0-dev is Mint's 2.52 headers, which the
# smoke test builds a second binary against to prove an app built on them runs on the bundle.
DEPS := cmake ninja-build gcc-14 g++-14 perl ruby python3 gperf pkgconf gpgv curl \
	libglib2.0-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev libgraphene-1.0-dev \
	libgcrypt20-dev libsoup-3.0-dev libtasn1-6-dev libharfbuzz-dev libicu-dev libjpeg-dev \
	libepoxy-dev libxml2-dev libxslt1-dev libpng-dev libsqlite3-dev zlib1g-dev libwebp-dev \
	libatspi2.0-dev libsecret-1-dev libdrm-dev libgbm-dev libenchant-2-dev libhyphen-dev \
	libjxl-dev libavif-dev liblcms2-dev libfreetype-dev libfontconfig-dev libexpat1-dev \
	libsystemd-dev libseccomp-dev libegl-dev libgles-dev libgl-dev libx11-dev libwayland-dev \
	wayland-protocols libxkbcommon-dev bubblewrap xdg-dbus-proxy \
	dpkg-dev binutils lintian shellcheck shfmt xvfb xauth libwebkitgtk-6.0-dev
APT_FLAGS ?=

init-packages: ## install the system packages a build, the test and the checks need (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# WebKit comes from its release tarball (`make build`), and nothing here has a lock of language
# packages. `ci` depends on it all the same, as in every repository.
init-modules: ## install the language packages from the lock: none here

init-workstation: hooks ## set up a desk: the git hooks and ccache (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(WORKSTATION_DEPS)

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(TARBALL):
	@echo "fetching webkitgtk $(VERSION)"
	mkdir -p build
	curl -fL -o $(TARBALL).part $(TARBALL_URL)
	curl -fL -o $(TARBALL).asc $(TARBALL_URL).asc
	@echo "$(TARBALL_SHA256)  $(TARBALL).part" | sha256sum -c - || { rm -f $(TARBALL).part $(TARBALL).asc; exit 1; }
	@rm -f build/webkitgtk-keyring.gpg; \
	gpg --dearmor < $(SIGNING_KEY) > build/webkitgtk-keyring.gpg && \
	gpgv --keyring "$(CURDIR)/build/webkitgtk-keyring.gpg" $(TARBALL).asc $(TARBALL).part || \
		{ echo "the signature does not verify: $(TARBALL) deleted"; rm -f $(TARBALL).part $(TARBALL).asc; exit 1; }
	mv $(TARBALL).part $(TARBALL)

# amber-gtk4's .pc files name prefix=/usr, where the package installs; for the build they are
# copied with the prefix moved to its stage, so pkg-config hands cmake the 4.16 headers and
# the staged libgtk-4.so to link. Only the prefix line changes.
gtk-pc:
	$(call require,AMBER_ROOT,$(GTK_STAGE)/usr/lib/amber-gtk4/pkgconfig/gtk4.pc,amber-gtk4,build amber-gtk4 first (make -C $(AMBER_ROOT)/amber-gtk4 build; make init-siblings clones it))
	@rm -rf $(GTK_PC) && mkdir -p $(GTK_PC)
	@for f in $(GTK_STAGE)/usr/lib/amber-gtk4/pkgconfig/*.pc; do \
		sed 's|^prefix=/usr$$|prefix=$(GTK_STAGE)/usr|' "$$f" > $(GTK_PC)/$${f##*/}; \
	done
	@v=$$(PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) pkg-config --modversion gtk4); \
	[ "$$v" = "$(GTK_BUNDLE_MIN)" ] || { echo "gtk-pc: amber-gtk4's stage is GTK $$v, this build expects $(GTK_BUNDLE_MIN)"; exit 1; }

# The configuration, flag by flag; docs/DECISIONS.md says why each feature is on or off.
#  - the GTK port, the GTK 4 API (webkitgtk-6.0), a Release build, with gcc-14
#  - the install layout above, and every ELF's RUNPATH the bundle's own directory, then
#    amber-gtk4's. WebKit links with --disable-new-dtags, which makes an RPATH; the _RELEASE
#    linker flags come after it on the link line, so --enable-new-dtags makes it a RUNPATH;
#    they also link with full RELRO and immediate binding, as the distro's packages are
#  - the source and build directories mapped out of __FILE__ and debug strings
#  - the sandbox on, with the helper paths fixed to the distro's (find_program would take the
#    first on the PATH)
#  - off: introspection and docs (nothing in the suite loads a typelib), MiniBrowser and
#    WebDriver (programs, not runtime), media (video, audio, MSE, EME, media stream and
#    recorder, WebCodecs, speech) and with it GStreamer, gamepads (libmanette), sysprof tracing
#    and libbacktrace (Mint has no libbacktrace-dev). unifdef is WebKit's bundled copy.
RELEASE_LDFLAGS = -Wl,--enable-new-dtags -Wl,-z,relro -Wl,-z,now
CMAKE_FLAGS = -G Ninja -DPORT=GTK -DUSE_GTK4=ON -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_COMPILER=gcc-14 -DCMAKE_CXX_COMPILER=g++-14 \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DCMAKE_INSTALL_LIBDIR=lib/amber-webkit \
	-DCMAKE_INSTALL_LIBEXECDIR=lib/amber-webkit \
	-DCMAKE_INSTALL_INCLUDEDIR=lib/amber-webkit/include \
	-DCMAKE_INSTALL_LOCALEDIR=share/amber-webkit/locale \
	-DCMAKE_INSTALL_RPATH=$(RUNPATH) \
	"-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=$(RELEASE_LDFLAGS)" \
	"-DCMAKE_EXE_LINKER_FLAGS_RELEASE=$(RELEASE_LDFLAGS)" \
	"-DCMAKE_MODULE_LINKER_FLAGS_RELEASE=$(RELEASE_LDFLAGS)" \
	"-DCMAKE_C_FLAGS=-ffile-prefix-map=$(CURDIR)/$(SRC)=webkit -ffile-prefix-map=$(CURDIR)/$(OBJ)=build" \
	"-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$(CURDIR)/$(SRC)=webkit -ffile-prefix-map=$(CURDIR)/$(OBJ)=build" \
	-DENABLE_BUBBLEWRAP_SANDBOX=ON -DBWRAP_EXECUTABLE=/usr/bin/bwrap \
	-DDBUS_PROXY_EXECUTABLE=/usr/bin/xdg-dbus-proxy \
	-DENABLE_INTROSPECTION=OFF -DENABLE_DOCUMENTATION=OFF \
	-DENABLE_MINIBROWSER=OFF -DENABLE_WEBDRIVER=OFF \
	-DUSE_GSTREAMER=OFF -DENABLE_VIDEO=OFF -DENABLE_WEB_AUDIO=OFF -DENABLE_MEDIA_SOURCE=OFF \
	-DENABLE_ENCRYPTED_MEDIA=OFF -DENABLE_MEDIA_STREAM=OFF -DENABLE_MEDIA_RECORDER=OFF \
	-DENABLE_WEB_CODECS=OFF -DENABLE_SPEECH_SYNTHESIS=OFF \
	-DENABLE_GAMEPAD=OFF -DUSE_SYSPROF_CAPTURE=OFF -DUSE_LIBBACKTRACE=OFF \
	-DUSE_SYSTEM_UNIFDEF=OFF

# The build sees the distro's tools only: a python3 or bwrap from mise or ~/.local would
# otherwise be what cmake finds, and the path it finds is compiled in.
BUILD_ENV = env PATH=/usr/bin:/bin PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) WEBKIT_NINJA_LINK_MAX=$(LINK_JOBS) $(CCACHE_ENV)

# The build is incremental: the source is unpacked and patched when the tarball or a patch
# changes, cmake runs when the configuration changes, and ninja carries on from where it
# stopped, so an interrupted build resumes.
$(SRC)/CMakeLists.txt: $(TARBALL) $(wildcard patches/*.patch)
	rm -rf build/webkit
	mkdir -p $(SRC)
	tar xf $(TARBALL) -C $(SRC) --strip-components=1
	# patches/ carries downstream fixes, applied with -N so a patch that stops applying
	# stops the build rather than shipping upstream's behaviour unannounced.
	@for p in patches/*.patch; do \
		test -e "$$p" || continue; \
		echo "applying $$p"; \
		patch -p1 -N -d $(SRC) --no-backup-if-mismatch --input="$(CURDIR)/$$p" || exit 1; \
	done
	@touch $@

# The configuration as one line, rewritten only when it changes, so cmake runs again only then.
CONFIG = build/webkit/config
.PHONY: FORCE

# A target whose recipe fails or is interrupted is removed, so it is never taken as made.
.DELETE_ON_ERROR:
$(CONFIG): FORCE
	@mkdir -p build/webkit
	@echo '$(CMAKE_FLAGS) $(CCACHE_FLAGS) LINK_JOBS=$(LINK_JOBS)' > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

$(OBJ)/build.ninja: $(SRC)/CMakeLists.txt $(CONFIG) | gtk-pc
	$(BUILD_ENV) cmake -S $(SRC) -B $(OBJ) $(CMAKE_FLAGS) $(CCACHE_FLAGS) > build/configure.log 2>&1 || \
		{ tail -40 build/configure.log; exit 1; }
	@touch $@

# Build WebKitGTK $(VERSION) for bundling: fetch, check, patch, configure, build, stage, strip.
# The configure and build output goes to build/configure.log and build/build.log.
build: $(OBJ)/build.ninja gtk-pc ## fetch, check, patch and build WebKitGTK into build/webkit/stage (about 20 minutes on 24 cores)
	@if [ -n "$(CCACHE)" ]; then echo "ccache: $(CCACHE), up to $(CCACHE_MAXSIZE) in its own folder"; \
	else echo "ccache: not installed, building without it (make init-workstation installs it)"; fi
	@echo "building with $(JOBS) jobs, $(LINK_JOBS) links at once; the log is build/build.log"
	$(BUILD_ENV) /usr/bin/time -v -o build/build-time.txt ninja -C $(OBJ) -j $(JOBS) > build/build.log 2>&1 || \
		{ grep -B2 -A20 -m3 'FAILED:' build/build.log || tail -60 build/build.log; exit 1; }
	rm -rf $(STAGE)
	DESTDIR=$(CURDIR)/$(STAGE) ninja -C $(OBJ) install > build/install.log 2>&1 || { tail -40 build/install.log; exit 1; }
	# CMake's gettext macro installs the catalogues to share/locale whatever LOCALEDIR says;
	# they go where the library looks for them, beside Mint's own without touching them.
	mkdir -p $(dir $(STAGE)$(LOCALE_DIR))
	mv $(STAGE)/usr/share/locale $(STAGE)$(LOCALE_DIR)
	# WebKit's .pc templates write includedir as ${prefix}/include whatever the include
	# directory is, and libdir as an absolute path; both are set to the bundle's, relative to
	# the prefix (scripts/check-pc checks them in the package).
	sed -i -e 's|^libdir=.*|libdir=$${prefix}/lib/amber-webkit|' \
		-e 's|^includedir=.*|includedir=$${prefix}/lib/amber-webkit/include|' $(BUNDLE)/pkgconfig/*.pc
	# Strip in place, so `make check` sees exactly what `make deb` ships; the compiler's
	# .comment section goes as well.
	find $(STAGE) -type f \( -name '*.so*' -o -perm -u+x \) -exec sh -c \
		'for f; do head -c4 "$$f" | grep -q ELF && strip --strip-unneeded --remove-section=.comment "$$f"; done' sh {} +

# The checks need the bundle. A WebKit build takes a while, so a checkout without one says so
# rather than starting it.
built:
	@test -e $(BUNDLE)/$(WEBKIT_SONAME) || { echo "$(BUNDLE)/$(WEBKIT_SONAME) is not there: make build first (about 20 minutes on 24 cores)"; exit 2; }

# What makes the bundle safe to ship, each enforced by a script:
#   1. it resolves against the distro's stock stack and amber-gtk4, and pulls nothing else in
#   2. it carries no path from the machine that built it
#   3. every ELF's RUNPATH is the bundle's then amber-gtk4's, the compiled-in helper and
#      injected-bundle paths are inside the bundle, and the sonames are Mint's
# The checks pass once per staged bundle: CHECKED is newer than the library and the scripts
# only after all three pass, so check, deb and deb-install skip them until either changes.
check: built $(CHECKED) ## the bundle pulls in no newer stack, carries no build paths, and keeps to its own paths

$(CHECKED): $(BUNDLE)/$(WEBKIT_SONAME) scripts/check-no-cascade scripts/check-no-buildpaths scripts/check-bundle-paths
	@scripts/check-no-cascade $(BUNDLE)/$(WEBKIT_SONAME) $(GTK_BUNDLE_DIR)
	@scripts/check-no-buildpaths $(BUNDLE)
	@scripts/check-bundle-paths $(BUNDLE) $(RUNPATH) $(WEBKIT_SONAME) $(JSC_SONAME)
	@touch $@

$(BUNDLE)/$(WEBKIT_SONAME):
	@echo "$@ is not there: make build first (about 20 minutes on 24 cores)"; exit 2

# The smoke test: a small GTK program loads a local page in a WebView under xvfb, and checks
# that it and every WebKit process it spawned map WebKit from the bundle and GTK from
# amber-gtk4 and nothing else (tests/run-smoke says how the staged tree stands in for the
# installed one).
test: built gtk-pc ## load a page off screen against the staged bundle and check what every process maps
	@tests/run-smoke $(STAGE) $(GTK_PC)

# What a push must pass without a build: the lint. A WebKit build takes about 20 minutes of a
# 24-core desk and more than 20 GB of memory, more than a CI run is for, so build, check, test
# and check-lintian run on a desk, with the package, before it is published.
# targets: ci runs no build, check or test (a WebKit build is 20 minutes and 20 GB; the desk runs them before a publish)
ci: init-modules lint ## everything a push must pass: the lint, no build
	@echo "CI OK: sources, scripts and packaging metadata check out (the build, test and lintian run on a desk)"

# The checks that need no build: the shell scripts, the docs, the packaging metadata.
check-sources: ## shellcheck, the changelog and control templates, and house-rules' narration and example-host checks where it is there
	@if [ -n "$(HOUSE_ROOT)" ] && [ -x "$(HOUSE_SCRIPTS)/check-narration" ]; then \
		"$(HOUSE_SCRIPTS)/check-narration" && "$(HOUSE_SCRIPTS)/check-example-hosts" "$(CURDIR)" || exit 1; \
	else echo "house-rules not found (HOUSE_ROOT=$(HOUSE_ROOT)): check-narration and check-example-hosts skipped; house-rules is private"; fi
	@git ls-files | while read -r f; do \
		case "$$f" in *.sh|*.bash) echo "$$f";; \
		*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
	done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"
	@dpkg-parsechangelog -l packaging/debian/changelog -S Version | grep -qx '$(VERSION)-$(REVISION)' || \
		{ echo "packaging/debian/changelog is not at $(VERSION)-$(REVISION)"; exit 1; }
	@test "$$(dpkg-parsechangelog -l packaging/debian/changelog -S Changes | grep -c '^  \*')" = 1 || \
		{ echo "packaging/debian/changelog has more than its one entry"; exit 1; }
	@for c in packaging/control.in packaging/control-dev.in; do \
		grep -q '^Package: ' $$c && grep -q '^Version: @VERSION@$$' $$c || { echo "$$c: no Package or Version line"; exit 1; }; \
	done
	@echo "check-sources OK"

# Two binary packages from the one build.
#   amber-webkit: the two libraries, the helper processes and the injected bundle under
#     /usr/lib/amber-webkit, and the translations under /usr/share/amber-webkit/locale.
#   amber-webkit-dev: the headers, the unversioned .so links and the .pc files, all under
#     /usr/lib/amber-webkit; the suite's binding is generated from these headers. It depends
#     on amber-gtk4-dev, whose GTK 4.16 the .pc files' gtk4 resolves to.
# Neither is on the ldconfig path, and neither has a shlibs file: only a binary whose RUNPATH
# names $(INSTALL_DIR) loads the bundle, so installing it changes nothing else on the system.
DEBROOT = build/deb/amber-webkit
DEVROOT = build/deb/amber-webkit-dev
deb: $(DEBS) ## package the bundle into dist/: amber-webkit and amber-webkit-dev

# Both packages come from one staging, so one rule makes them together, and only when the
# checked bundle or what goes into a package changed: an up-to-date pair is installed or
# ingested as it is. A recipe that fails or is interrupted deletes them (.DELETE_ON_ERROR), so
# a half-written package never counts as made.
$(DEBS) &: $(CHECKED) packaging/control.in packaging/control-dev.in packaging/debian/copyright packaging/debian/changelog $(wildcard packaging/lintian-overrides/*) scripts/check-no-buildpaths scripts/check-pc Makefile
	rm -rf build/deb build/shlibwork
	install -d $(DEBROOT)$(INSTALL_DIR) $(DEVROOT)$(INSTALL_DIR)
	# The real files and their soname links; the unversioned links belong to -dev.
	cp -a $(BUNDLE)/libwebkitgtk-6.0.so.* $(BUNDLE)/libjavascriptcoregtk-6.0.so.* $(DEBROOT)$(INSTALL_DIR)/
	cp -a $(BUNDLE)/webkitgtk-6.0 $(DEBROOT)$(INSTALL_DIR)/
	# The jsc shell WebKit installs beside the helpers is a developer's tool; nothing runs it.
	rm $(DEBROOT)$(INSTALL_DIR)/webkitgtk-6.0/jsc
	install -d $(DEBROOT)$(LOCALE_DIR)
	cp -a $(STAGE)$(LOCALE_DIR)/. $(DEBROOT)$(LOCALE_DIR)/
	cp -a $(BUNDLE)/libwebkitgtk-6.0.so $(BUNDLE)/libjavascriptcoregtk-6.0.so $(BUNDLE)/include $(BUNDLE)/pkgconfig $(DEVROOT)$(INSTALL_DIR)/
	# Assert on what is packaged, both packages, not only on what was staged: `make deb` is not a
	# way around `make check`.
	@scripts/check-no-buildpaths build/deb
	# The .pc files require gtk4, which amber-webkit-dev takes from amber-gtk4-dev: check-pc
	# resolves it in amber-gtk4's stage and fails on a GTK older than 4.16.
	$(call require,AMBER_ROOT,$(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig/gtk4.pc,amber-gtk4,build amber-gtk4 first (make -C $(AMBER_ROOT)/amber-gtk4 build; make init-siblings clones it))
	@PKG_CONFIG_PATH=$(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig scripts/check-pc $(DEVROOT)$(INSTALL_DIR)/pkgconfig $(INSTALL_DIR)
	@set -e; for p in amber-webkit amber-webkit-dev; do \
		root=build/deb/$$p; \
		install -D -m644 packaging/lintian-overrides/$$p $$root/usr/share/lintian/overrides/$$p; \
		install -D -m644 packaging/debian/copyright $$root/usr/share/doc/$$p/copyright; \
		gzip -9n < packaging/debian/changelog > $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		chmod 644 $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		find $$root -type d -exec chmod 755 {} +; \
		mkdir -p $$root/DEBIAN; \
		(cd $$root && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums); \
	done
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-webkit\n\nPackage: amber-webkit\nArchitecture: amd64\n' > build/shlibwork/debian/control
	# -l: the bundle's own libraries are found in the package, not as Mint's 2.52 ones.
	# --ignore-missing-info: amber-gtk4 ships no shlibs file by design; control.in names it.
	# Whatever shlibdeps still resolves to Mint's GTK or WebKit packages is never loaded,
	# since the RUNPATH reaches the bundles first, so those claims are dropped.
	# libEGL is dlopened, not linked, so shlibdeps never sees it: control.in names libegl1.
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info -l../../$(DEBROOT)$(INSTALL_DIR) \
		$$(find ../../$(DEBROOT)$(INSTALL_DIR) -type f \( -name '*.so*' -o -perm -u+x \) | sort) > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk $(DEBROOT) --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed -e 's/^shlibs:Depends=//' -e 's/\(libgtk-4-1\|libwebkitgtk-6.0-4\|libjavascriptcoregtk-6.0-1\) ([^)]*)\(, \)\?//g' -e 's/, $$//' build/shlibwork/deps.txt)|" \
		packaging/control.in > $(DEBROOT)/DEBIAN/control
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk $(DEVROOT) --exclude=DEBIAN | cut -f1)/" \
		packaging/control-dev.in > $(DEVROOT)/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group $(DEBROOT) $(DEB)
	dpkg-deb --build --root-owner-group $(DEVROOT) $(DEV_DEB)

# Where `make deb` puts the packages: one absolute path a line, nothing else.
# amberlinux-apt ingests them through this.
deb-path: ## print the absolute paths of the two .debs, one a line
	@for d in $(DEBS); do echo "$(CURDIR)/$$d"; done

deb-install: $(DEBS) ## install both .debs, packaging them first if the bundle changed (sudo)
	# --allow-downgrades: once the packages are published, the archive carries the same
	# version at a higher pin priority than a local file, so apt reads installing your own
	# build as a downgrade and refuses.
	sudo apt install --reinstall --allow-downgrades $(patsubst %,./%,$(DEBS))

deb-remove: ## remove the installed packages (sudo)
	sudo apt remove amber-webkit-dev amber-webkit

# build/ holds the WebKit build as well: after a clean, `make build` compiles everything again,
# from ccache where the desk has it.
clean: ## remove build/ and dist/, the WebKit build included
	rm -rf build dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/|\.codex/|AGENTS\.md|CLAUDE\.md)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber .codex AGENTS.md CLAUDE.md; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored: 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: check check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	other_wt="$$(git worktree list --porcelain | awk -v b="branch refs/heads/$(BRANCH)" '/^worktree /{w=substr($$0, 10)} $$0 == b {print w}')"; \
	if [ -n "$$other_wt" ] && [ "$$other_wt" != "$$(git rev-parse --show-toplevel)" ]; then \
		git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 || true; \
		git checkout -q --detach; git branch -D "$$tmp_branch" >/dev/null; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
		echo "$(BRANCH) is checked out in $$other_wt; once it is clean: git -C $$other_wt fetch && git -C $$other_wt reset --keep $(REMOTE)/$(BRANCH)"; \
	else \
		git branch -M "$$tmp_branch" "$(BRANCH)"; \
		git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
	fi

# lint needs no build: the formatting, the agent-file guard and the source checks.
lint: check-fmt check-no-agent-files check-sources ## check-fmt, the agent-file guard and check-sources
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed, run 'make hooks'"

# lintian reads the packages, so it needs the build; a desk runs it before a publish.
check-lintian: deb ## lintian on both packages (needs the build)
	@if command -v lintian >/dev/null; then \
		lintian --tag-display-limit 0 -L '>=pedantic' --fail-on error,warning $(DEBS) && echo "lintian OK"; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo "lintian is not installed on this runner; make init-packages installs it"; exit 1; \
	else echo "lintian not installed: skipping (make init-packages installs it)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"

# Shell scripts are laid out by shfmt (sudo apt install shfmt), with tabs: every tracked file
# that is a shell script by its name or its first line.
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard -- . | xargs -0 -r $(SHFMT) -f
.PHONY: fmt check-fmt fmt-sh check-fmt-sh
fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; make init-packages installs it"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

fmt: fmt-sh ## format the code in place: here, the shell scripts
check-fmt: check-fmt-sh ## fail on code that is not as make fmt leaves it

# --- siblings: house-rules scripts/binding/siblings.mk, the same in every repository with a siblings.txt ---
# siblings.txt names the repositories this one needs beside it, one a line, as
# `<ROOT_VARIABLE>,https://github.com/<owner>/<name>`; `#` starts a comment and blank lines are
# skipped. `make init-siblings` clones each one that is missing, from the URL as written, into
# `$(<ROOT_VARIABLE>)/<name>`, <name> being the URL's last part without `.git`. A checkout
# already there is left as it is: no pull, no reset, no checkout. Each variable is set in the
# environment or on the command line: mise at a desk, the workflow in CI, each to a folder above
# its workspace. It is part of `setup` (the rule below adds it, first, when this block stands
# above the `setup` rule) and never of `ci`.
SIBLING_ROOTS = $(foreach v,$(filter %_ROOT,$(.VARIABLES)),$(if $(filter environment% command%,$(origin $(v))),$(v)))
.PHONY: init-siblings
init-siblings: ## clone the repositories siblings.txt names that are missing from their roots; one already there is left as it is
	@sed 's/#.*//' siblings.txt | tr -d ' \t\r' | while IFS= read -r line; do \
		[ -n "$$line" ] || continue; \
		var=$${line%%,*}; url=$${line#*,}; \
		printf '%s\n' "$$var" | grep -Eqx '[A-Z_]+_ROOT' && [ "$$var" != "$$line" ] || \
			{ echo "init-siblings: '$$line' in siblings.txt does not start with a root variable and a comma (AMBER_ROOT,https://github.com/<owner>/<name>)" >&2; exit 2; }; \
		printf '%s\n' "$$url" | grep -Eqx 'https://github\.com/[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*' || \
			{ echo "init-siblings: '$$url' in siblings.txt is not https://github.com/<owner>/<name>" >&2; exit 2; }; \
		name=$${url##*/}; name=$${name%.git}; \
		case " $(SIBLING_ROOTS) " in *" $$var "*) ;; \
		*) echo "init-siblings: $$var is not set: it names the root $$name goes in (mise sets it at a desk; a workflow sets it to a folder above its workspace)" >&2; exit 2 ;; esac; \
		root=$$(printenv "$$var") || root=; root=$${root%/}; \
		[ -n "$$root" ] || { echo "init-siblings: $$var is empty" >&2; exit 2; }; \
		dest=$$root/$$name; \
		if [ -e "$$dest" ]; then echo "init-siblings: $$name is there, $$dest"; continue; fi; \
		echo "init-siblings: cloning $$name into $$dest"; \
		git clone -q "$$url" "$$dest" || exit 1; \
	done

setup: init-siblings

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: siblings, packages (sudo apt), then hooks
