#!/bin/sh
# Runs the test suite with the Command Line Tools' Swift Testing paths.
# (Needed with CLT-only installs where SwiftPM doesn't add them itself; see docs/development.md.)
CLT=/Library/Developer/CommandLineTools/Library/Developer
exec swift test \
  -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
  -Xlinker -F -Xlinker "$CLT/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
