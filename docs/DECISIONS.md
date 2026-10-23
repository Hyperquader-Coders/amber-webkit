# Decisions: amber-webkit

What was weighed and settled, with the reasons that make each choice hold. An entry that stops
being true is rewritten, not appended to.

1. **The suite carries its own WebKitGTK, 2.54.1, rather than Mint's.** Linux Mint 22 ships
   WebKitGTK 2.52.6 (Ubuntu noble's security updates). On this machine's NVIDIA driver 2.52.6
   leaks DMA-BUF render buffers on a page that composites every frame until WebKit kills the
   page process at 16 GB (amber-browser's DECISIONS, 8). 2.54 moves the web process's
   compositor to Skia and reworks damage handling, which is where that leak lives; and noble
   takes upstream's security releases weeks after they ship. Turned down: staying on the
   distro's WebKit, because the leak is in the version it ships and its updates follow upstream
   at the distro's pace. The cost is that this package must follow upstream's stable releases
   itself: a new release is `VERSION` and `TARBALL_SHA256` in the Makefile and a rebuild.

2. **A runtime bundle in /usr/lib/amber-webkit, reached through RUNPATH.** The libraries, the
   helper processes and the injected bundle live in `/usr/lib/amber-webkit`, which is not on
   the ldconfig path and has no shlibs file, as amber-gtk4 and amber-vte are. Only a binary
   whose RUNPATH names the directory loads it, so installing the package changes nothing else
   on the system, and Mint's WebKit can stay installed beside it. Every ELF in the bundle
   carries `RUNPATH /usr/lib/amber-webkit:/usr/lib/amber-gtk4`: a RUNPATH is not inherited by
   the libraries a program loads, so each object names both bundles itself. WebKit links with
   `--disable-new-dtags`, which writes an RPATH; the Makefile puts `--enable-new-dtags` in the
   Release linker flags, which come after it on the link line, so the objects carry a RUNPATH.
   `scripts/check-bundle-paths` asserts all of it.

3. **Compiled against amber-gtk4's GTK 4.16 headers, not Mint's 4.14.** WebKit's accelerated
   backing store hands frames to GTK as `GdkMemoryTextureBuilder` textures with damage regions
   when `GTK_CHECK_VERSION(4, 16, 0)` holds at compile time, and as cairo surfaces otherwise.
   The bundle always runs on amber-gtk4's 4.16, so it is built with the 4.16 path: the Makefile
   points pkg-config at copies of amber-gtk4's staged `.pc` files with the prefix moved to its
   stage (`siblings.txt` names amber-gtk4), and `check-bundle-paths` fails a library that does
   not import `gdk_memory_texture_builder_new`. WebKit 2.54.1 needs GTK 4.6 or later, so 4.16
   needs no change to amber-gtk4. Turned down: building against Mint's `libgtk-4-dev`, which
   compiles the cairo path into a library that only ever runs on 4.16.

4. **Features that pull in a stack the apps do not use are built out.** Trapwood and kat800's
   web tab turn media off in WebKit's settings, so the bundle is built without it:
   `ENABLE_VIDEO`, `ENABLE_WEB_AUDIO`, `ENABLE_MEDIA_SOURCE`, `ENABLE_ENCRYPTED_MEDIA`,
   `ENABLE_MEDIA_STREAM`, `ENABLE_MEDIA_RECORDER`, `ENABLE_WEB_CODECS` and
   `ENABLE_SPEECH_SYNTHESIS` are off, and with them `USE_GSTREAMER`, which removes GStreamer
   and its plugins from the dependencies. Also off: `ENABLE_GAMEPAD` (libmanette; no app reads
   gamepads), `ENABLE_INTROSPECTION` and `ENABLE_DOCUMENTATION` (nothing in the suite loads a
   typelib; the binding is generated from the headers), `ENABLE_MINIBROWSER` and
   `ENABLE_WEBDRIVER` (programs, not runtime), `USE_SYSPROF_CAPTURE` (tracing) and
   `USE_LIBBACKTRACE` (Mint has no `libbacktrace-dev`). unifdef, a build tool, is WebKit's
   bundled copy (`USE_SYSTEM_UNIFDEF=OFF`). Kept: the bubblewrap sandbox, JavaScriptCore,
   WebGL (ANGLE) and the GPU process, spell checking (enchant), the credential store
   (libsecret), hyphenation, XSLT, AVIF, JPEG XL and WebP, colour management (lcms2), journald
   logging, the PDF viewer, and both X11 and Wayland. A page that plays media gets WebKit's
   unsupported-media behaviour, which is what the apps' settings already ask for.

5. **Two packages from one build: amber-webkit and amber-webkit-dev.** The runtime package
   holds what a running app loads. The -dev package holds the headers, the unversioned `.so`
   links and the `.pc` files, all under `/usr/lib/amber-webkit` (`include/`, `pkgconfig/`), so
   they never meet Mint's `libwebkitgtk-6.0-dev`. The headers ship because the suite's Odin
   binding, odin-webkit, is generated with runic from this bundle's 2.54.1 headers and links
   `webkitgtk-6.0` and `javascriptcoregtk-6.0` at build time; the apps then compile and link
   against the bundle they run on. The `.pc` files' `libdir` and `includedir` point into the
   bundle (`scripts/check-pc`); WebKit's templates write `includedir` as `${prefix}/include`
   whatever the include directory is, so the build rewrites both lines after staging. The
   jsc shell, a developer's tool WebKit installs beside the helpers, is left out. The
   translations go to `/usr/share/amber-webkit/locale`, since Mint's `libwebkitgtk-6.0-4` owns
   `/usr/share/locale/*/LC_MESSAGES/WebKitGTK-6.0.mo`; the path is compiled into the library,
   and CMake's gettext macro installs to `share/locale` whatever it says, so the build moves
   the catalogues there after staging.

6. **The sonames stay Mint's.** 2.54's libtool triples give `libwebkitgtk-6.0.so.4` and
   `libjavascriptcoregtk-6.0.so.1`, the sonames of Mint's 2.52 packages, so a program built
   against either set of headers resolves the bundle through its RUNPATH. `make check` fails if
   a release moves them, and the smoke test runs a program built against Mint's 2.52 headers
   on the bundle.

7. **The tarball is checked against a pinned sha256 and upstream's signature.** The sha256 is
   the one in the `.sums` file webkitgtk.org publishes, and the `.asc` signature is checked
   with gpgv against the release key in `packaging/upstream/`. That key is Carlos García
   Campos's (`013A 0127 AC9C 65B3 4FFA 6252 6C10 09B6 9397 5393`, listed on
   webkitgtk.org/verifying.html), taken from keys.openpgp.org, whose copy runs to 2028; the
   copy on webkitgtk.org expired on 9 April 2026 and does not verify the 2.54.1 signature.

8. **`make ci` builds nothing.** A WebKit build takes about 20 minutes of a 24-core desk and
   more than 20 GB of memory (11), more than a CI run is for, so `ci` runs shfmt, shellcheck,
   the agent-file guard and `check-sources` (the changelog and control templates, and
   house-rules' narration and example-host checks). The build, `check`, `test`, `deb` and
   `check-lintian` run on a desk before a package is published. The repository is public and
   house-rules is private, so house-rules is not in `siblings.txt`: where `HOUSE_ROOT` does not
   hold it, as on GitHub's runner, `check-sources` says it skips those two checks, as
   amber-gtk4 does.

9. **The smoke test runs the staged tree in a private mount namespace.** A release build of
   WebKit starts its helper processes only from the directory compiled into the library, so
   `LD_LIBRARY_PATH` cannot stand the stage in for the installed package. `tests/run-smoke`
   runs each test program in an unprivileged user and mount namespace in which `/usr/lib` is an
   overlay with the stage's `usr/lib` on top; there `/usr/lib/amber-webkit` is the staged
   bundle at its installed path, and WebKit's own bwrap sandbox runs inside it. The program
   then reads `/proc/<pid>/maps` of itself and every process below it. Turned down: testing
   only after `make deb-install`, which needs sudo and tests a package before it is checked;
   and `WEBKIT_EXEC_PATH`, which a release build ignores.

10. **gcc-14.** WebKit 2.54 needs GCC 12 or Clang 19 at least; Mint has gcc 13 and 14 and
    Clang 18. gcc-14 is the newest compiler Mint carries that WebKit supports, and amber-vte
    builds with it as well.

11. **12 compile jobs and two links by default.** Measured on the 24-core, 62 GB desk: 24 jobs
    took the machine to 59 GB used with swap full, which leaves the owner's programs to the OOM
    killer; 12 jobs peaked at 41 GB, about 21 GB above the desk's own use, and the whole build
    took 19 minutes (11 at 24 jobs, 8 at 12). WebKit's own link pool keeps the links, the
    heaviest steps at up to 4.9 GB each, at two at once. `JOBS` and `LINK_JOBS` lower both on a
    smaller desk.

12. **ccache on a desk, never in CI.** `make init-workstation` installs it; `make build` names it
    as the compiler launcher when it is installed and otherwise turns off WebKit's own
    detection (`WK_USE_CCACHE=NO`), so the first line of the build says which. The cache stays
    in ccache's own folder, so it survives `make clean` and serves every worktree:
    `CCACHE_BASEDIR` and `CCACHE_NOHASHDIR` make what it hashes independent of the checkout's
    path (measured: the same source under two paths with this build's `-ffile-prefix-map`
    hits). The size, 12 GB, is set in the build's environment, not the desk's ccache.conf: one
    build writes 0.4 GB of objects and 4.9 GB of precompiled headers. WebKit compiles with
    precompiled headers, which ccache caches only with `pch_defines,time_macros` sloppiness and
    `CCACHE_PCH_EXTSUM`. Turned down: ccache in `init-packages`, which CI runs.

13. **Hardened links, stripped objects.** The objects link with full RELRO and immediate
    binding (`-z relro -z now`), as the distro's packages do, and are stripped with their
    `.comment` section; lintian then reports nothing but what the overrides in
    `packaging/lintian-overrides/` name: the RUNPATH to amber-gtk4, upstream's misspelt
    messages, and the bug-closing entry an initial upload outside Debian has none for.
