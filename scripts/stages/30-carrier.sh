#!/bin/sh
# Contract: input=staged carrier assets; preconditions=clean Zygote setting;
# output=live validated carrier identity + boot-scoped PID/ABI evidence.
# Idempotent=yes for a valid live carrier. Binder primitive=no. Carrier creation
# may consume this boot's Zygote one-shot. Failure never marks Binder spent.
# Safe retry=only if failure was before/without an uncertain injection.
# Next: leak.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=carrier
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/state.sh"
. "$SNUSNU_REPO_DIR/scripts/lib/carrier.sh"

require_device
exempt="$(device_value 'settings get global hidden_api_blacklist_exemptions')"
[ "$exempt" = null ] || [ -z "$exempt" ] \
    || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE stale_hidden_api_exemptions
if carrier_ping; then
    echo 'carrier=reused'
else
    echo 'carrier=spawning'
    carrier_spawn || stage_fatal "$STAGE_NAME" CARRIER_FAILURE carrier_start_failed 21
fi
carrier_validate_live \
    || stage_fatal "$STAGE_NAME" CARRIER_FAILURE "$CARRIER_VALIDATION_ERROR" 22
boot="$(current_boot_id)"
state_record carrier success "$boot" "pid=$CARRIER_PID,abi=$CARRIER_ABI,elf=$CARRIER_ELF"
carrier_print
echo "boot_id=$boot"
stage_ok "$STAGE_NAME"

