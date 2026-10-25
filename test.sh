#!/bin/zsh
# Runs the logic tests in Tests/: the pure functions behind breaks, schedules and history.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
swiftc -parse-as-library -D TESTING -target arm64-apple-macos14 Sources/*.swift Tests/*.swift -o $BUILD/tests
$BUILD/tests
rm -r "$BUILD"
