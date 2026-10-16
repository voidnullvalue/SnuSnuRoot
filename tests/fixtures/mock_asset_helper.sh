#!/bin/sh
set -eu
[ -z "${MOCK_ASSET_LOG:-}" ] || echo "${1:-}" >>"$MOCK_ASSET_LOG"
echo 'agent.jar=ready sha256=mock'
echo 'libhwbinder_target.arm64-v8a.so=ready sha256=mock'
echo 'libhwbinder_target.armeabi-v7a.so=ready sha256=mock'

