# patches

Downstream fixes applied to the WebKitGTK tarball before `cmake`. `make build` applies every
`*.patch` here with `patch -p1 -N` and stops the build if one fails, so a patch that no longer
applies to a new WebKit is a build error rather than a bundle that silently ships upstream's
behaviour.

Each patch carries, in its own header, what it fixes and how that was measured. A patch is
deleted once upstream WebKit has fixed what it works around.

The bundle builds 2.54.1 unpatched: there are none.
