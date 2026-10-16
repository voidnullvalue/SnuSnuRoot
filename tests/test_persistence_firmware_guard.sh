#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
javac -source 8 -target 8 -d "$tmp" \
    "$repo_dir/poc/snusnu-persist-app/src/io/github/voidnullvalue/snusnuroot/persistence/FirmwareGuard.java" \
    "$repo_dir/tests/java/io/github/voidnullvalue/snusnuroot/persistence/FirmwareGuardTest.java"
java -cp "$tmp" io.github.voidnullvalue.snusnuroot.persistence.FirmwareGuardTest
