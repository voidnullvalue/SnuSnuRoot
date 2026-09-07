#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_dir/scripts/phase_b_status.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ "$(phase_b_retry_action "$PHASE_B_STATEFUL_SPENT")" = RETRY_FRESH_BOOT ] \
    || fail "spent stateful primitive must use a fresh boot"
[ "$(phase_b_failure_name "$PHASE_B_VALIDATION")" = carrier_validation ] \
    || fail "validation failure name is unstable"
for result in "$PHASE_B_PRECHECK" "$PHASE_B_CARRIER_START" \
    "$PHASE_B_VALIDATION" "$PHASE_B_WAITER_STATE" "$PHASE_B_POST_WRITE" 1; do
    [ "$(phase_b_retry_action "$result")" = ABORT ] \
        || fail "failure $result must not trigger an automatic retry"
done
[ "$(waiter_state_for_value 1788785208143 trigger)" = 'NUMERIC(1788785208143)' ] \
    || fail "numeric normalized waiter state was not detected"
[ "$(waiter_state_for_value trigger trigger)" = ARMED ] \
    || fail "armed waiter state was not detected"
[ "$(waiter_state_for_value broken trigger)" = 'INVALID(broken)' ] \
    || fail "invalid waiter state was not detected"
echo "PASS: Phase B retry classification"
