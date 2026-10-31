# amber-webkit

One WebKitGTK 2.54 build (the GTK 4 API, `webkitgtk-6.0`) shared by the
[Amber Linux](https://amberlinux.org) applications, built against the suite's GTK 4.16
([amber-gtk4](https://github.com/Hyperquader-Coders/amber-gtk4)), installed to
`/usr/lib/amber-webkit` and reached only through those applications' RUNPATH. Trapwood and
KAT800's web tab use it through amber-browser and the odin-webkit binding.

Written with AI assistance.

## Why it exists

Linux Mint 22 ships WebKitGTK 2.52.6. On an NVIDIA driver it leaks render buffers on a page that
composites every frame until WebKit kills the page at 16 GB, and its security updates reach Mint
weeks after upstream releases them. 2.54 moves the web process's compositor to Skia and reworks
damage handling. The suite carries one build of the current stable release, and every
application points at it. [docs/DECISIONS.md](docs/DECISIONS.md) has the reasons in full.

## Install

From the suite's apt archive:

```sh
sudo curl -fsSL -o /usr/share/keyrings/amberlinux-archive-keyring.gpg \
  https://apt.amberlinux.org/amberlinux-archive-keyring.gpg

echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/amberlinux-archive-keyring.gpg] https://apt.amberlinux.org amber main' \
  | sudo tee /etc/apt/sources.list.d/amberlinux.list

sudo apt update
sudo apt install amber-webkit
```

Check the key before trusting it: `gpg --show-keys /usr/share/keyrings/amberlinux-archive-keyring.gpg`
should show `481A 11AA 5483 3219 6B29  0D09 C5B0 67A7 99C4 3065`, "Amber Linux Archive Signing
Key".

Applications that need it declare `Depends: amber-webkit`, so installing one of them installs
this. It depends on amber-gtk4, bubblewrap and xdg-dbus-proxy (the sandbox).

## Who uses it

Trapwood, the suite's browser, and KAT800's web tab show web pages through amber-browser, which
calls WebKit through the odin-webkit binding. odin-webkit is generated from amber-webkit-dev's
headers and links the bundle's libraries; each application carries the RUNPATH below, so at run
time it loads this WebKit and amber-gtk4's GTK, whatever else is installed.

## What the packages contain

**amber-webkit**, the runtime:

| path | what |
|---|---|
| `/usr/lib/amber-webkit/libwebkitgtk-6.0.so.4` | WebKit, stripped |
| `/usr/lib/amber-webkit/libjavascriptcoregtk-6.0.so.1` | JavaScriptCore, stripped |
| `/usr/lib/amber-webkit/webkitgtk-6.0/` | the web, network and GPU processes and the injected bundle |
| `/usr/share/amber-webkit/locale/` | WebKit's translations |
| `/usr/share/doc/amber-webkit/` | copyright and changelog |

**amber-webkit-dev**, for building against the bundle:

| path | what |
|---|---|
| `/usr/lib/amber-webkit/include/webkitgtk-6.0/` | the WebKit and JavaScriptCore headers |
| `/usr/lib/amber-webkit/pkgconfig/` | `webkitgtk-6.0.pc`, `javascriptcoregtk-6.0.pc`, `webkitgtk-web-process-extension-6.0.pc` |
| `/usr/lib/amber-webkit/libwebkitgtk-6.0.so`, `libjavascriptcoregtk-6.0.so` | the links a linker looks for |

`/usr/lib/amber-webkit` is not on the `ldconfig` path. Only a binary whose RUNPATH names that
directory picks the bundle up, so installing it changes nothing for any other program, and
Mint's own WebKit can stay installed beside it. The sonames are Mint's, so a program built
against Mint's `libwebkitgtk-6.0-dev` runs on the bundle as well.

Media playback, WebAudio, WebRTC, WebCodecs, gamepads and speech synthesis are not built: the
apps turn media off, and leaving it out removes GStreamer from the dependencies.

## What the build enforces

| check | asserts |
|---|---|
| `scripts/check-no-cascade` | every library the bundle needs is its own, amber-gtk4's GTK, or a file a distro package owns |
| `scripts/check-no-buildpaths` | no path from the build machine is compiled in, on the stage and again in the package |
| `scripts/check-bundle-paths` | every object's RUNPATH is `/usr/lib/amber-webkit:/usr/lib/amber-gtk4`; the sonames are Mint's; the helper, injected-bundle and locale directories compiled in are the bundle's; it was compiled against GTK 4.16 |
| `scripts/check-pc` | the `.pc` files' `libdir` and `includedir` are inside the bundle, and the `gtk4` they require resolves to amber-gtk4's 4.16 |
| `tests/run-smoke` | a GTK program loads a local page off screen, and it and every WebKit process it starts map WebKit only from the bundle and GTK only from amber-gtk4 |

## Consuming it

Build against the bundle's headers and amber-gtk4's, so `gtk4` is GTK 4.16 and not Mint's 4.14
(amber-webkit-dev depends on amber-gtk4-dev), and point the release RUNPATH at both bundles:

```sh
export PKG_CONFIG_PATH=/usr/lib/amber-webkit/pkgconfig:/usr/lib/amber-gtk4/pkgconfig
cc app.c $(pkg-config --cflags --libs webkitgtk-6.0) \
  -Wl,--enable-new-dtags,-rpath,/usr/lib/amber-webkit:/usr/lib/amber-gtk4
```

Depend on it:

```
Depends: amber-webkit (>= 2.54.1)
```

Check a shipped binary with `ldd`: `libwebkitgtk-6.0.so.4` resolves to
`/usr/lib/amber-webkit/libwebkitgtk-6.0.so.4`, and `libgtk-4.so.1` to
`/usr/lib/amber-gtk4/libgtk-4.so.1`.

## Building

Requires Linux Mint 22 or Ubuntu 24.04, and amber-gtk4 built beside this checkout: WebKit
compiles against amber-gtk4's staged GTK 4.16 headers. `siblings.txt` names the repositories
this one needs beside it, one a line with the root variable whose folder it goes in
(`AMBER_ROOT,https://github.com/Hyperquader-Coders/amber-gtk4`); `make setup`, or
`make init-siblings`, clones the missing ones there and leaves a checkout already there as it is.

| target | does |
|---|---|
| `make setup` | after a fresh clone: `init-siblings`, `init-packages`, `init-modules` and `init-workstation` |
| `make init-packages` | installs cmake, ninja, gcc-14 and WebKit's build dependencies (sudo apt) |
| `make init-modules` | nothing: no language packages here (`ci` runs it, as in every repository) |
| `make init-workstation` | the git hooks and ccache (sudo apt); a desk only, never CI |
| `make build` | fetches the release tarball into `build/`, checks its sha256 and its signature, applies `patches/`, configures, builds, stages under `build/webkit/stage` and strips. The logs are `build/configure.log` and `build/build.log` |
| `make check` | the four assertions above, against the staged bundle |
| `make test` | the smoke test, against the staged bundle |
| `make deb` | `dist/amber-webkit_<version>-<revision>_amd64.deb` and `dist/amber-webkit-dev_…`, made again only when the checked bundle or a packaging file changed; re-runs the build-path check on the packaged tree |
| `make deb-install` / `make deb-remove` | install or remove both packages locally; an up-to-date pair is installed as it is |
| `make deb-path` | the packages' absolute paths, one a line, for the apt archive's ingest |
| `make lint` | shfmt, shellcheck, the agent-file guard and the source checks, with no build |
| `make check-lintian` | lintian on both packages, after `make deb` |
| `make ci` | what a push must pass: `make lint`, without the build |
| `make clean` | removes `build/` and `dist/`, the WebKit build included |

**The build's cost.** On a 24-core desk with 62 GB, WebKit 2.54.1 took 19 minutes to compile
and link (11 at 24 jobs, then 8 at 12). 24 jobs took the machine to 59 GB used with swap full;
12 jobs peaked at 41 GB, about 21 GB above the desk's own use. So `make build` runs 12 compile
jobs and two links at once by default. A smaller desk lowers both: `make build JOBS=6 LINK_JOBS=1`.

**ccache.** `make init-workstation` installs ccache, and `make build` uses it whenever it is
installed, saying so in its first line. The cache stays in ccache's own folder, so it survives
`make clean` and serves every worktree: the paths it hashes are made relative to the checkout.
The build gives ccache 12 GB, through its own environment rather than the desk's ccache.conf:
one build writes 0.4 GB of objects and 4.9 GB of precompiled headers, so the cache holds two.

**The build is incremental.** The source is unpacked again only when the tarball or a patch
changes, cmake runs again only when the configuration changes, and an interrupted build carries
on where it stopped.

**CI** runs `make ci` on GitHub's runner: the source and packaging checks. It does not build
WebKit, which is more than a CI run is for; the build, `make check`, `make test` and lintian run
on a desk before a package is published. house-rules, whose narration and example-host checks
`make ci` runs where it is there (`HOUSE_ROOT`), is private, so the runner skips those two and
says so.

## Upgrading WebKit

1. Set `VERSION` and `TARBALL_SHA256` in the `Makefile`; the sum is in the
   `webkitgtk-<version>.tar.xz.sums` file beside the tarball on webkitgtk.org.
2. `make build && make check && make test`. If the sonames move, every consumer is rebuilt.
3. If a patch no longer applies, `make build` stops. Rebase it, or delete it if upstream has
   fixed the problem.
4. Bump the `Depends` floor in each consuming application.

## Licence

The packaging in this repository (Makefile, scripts, the smoke test, Debian metadata, patches)
is Copyright © 2025 Andre Bremer <hyperquader@gmail.com>, https://hyperquader.com, under
LGPL-2.1-or-later, the licence of most of the software it packages. WebKitGTK is Copyright ©
Apple Inc. and the WebKit contributors under LGPL-2 or later, LGPL-2.1 or later and BSD
licences, with bundled parts (Skia, ANGLE, pdf.js and others) under their own;
`packaging/debian/copyright` lists them. This repository ships no WebKit source: `make build`
fetches the upstream release tarball. [`LICENSE`](LICENSE) is the LGPL 2.1 text verbatim.
