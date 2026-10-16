#!/bin/sh
set -eu
stage="$1"
echo "$stage" >>"$MOCK_STAGE_LOG"
if [ "${MOCK_FAIL_STAGE:-}" = "$stage" ]; then
    if [ "$stage" = leak ]; then
        count=0
        [ ! -f "$MOCK_STAGE_COUNT" ] || count="$(cat "$MOCK_STAGE_COUNT")"
        count=$((count + 1))
        echo "$count" >"$MOCK_STAGE_COUNT"
        exit 30
    fi
    exit "${MOCK_FAIL_CODE:-22}"
fi
echo "STAGE_OK $stage"

