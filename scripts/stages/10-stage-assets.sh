#!/bin/sh
# Contract: input=packaged agent/JNI/helpers; precondition=authorized device and
# UID-1000 channel if updates are needed; output=verified device hashes.
# Idempotent=yes. Fresh boot=no. Binder=no. Safe retry=yes. Zygote one-shot=no
# when current; installing missing secured files may create/reuse the platform's
# UID-1000 channel and is reported explicitly. Next: arm-waiter or carrier.
set -eu
SNUSNU_REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
STAGE_NAME=stage-assets
. "$SNUSNU_REPO_DIR/scripts/lib/common.sh"

require_device
asset_helper="${SNUSNU_ASSET_HELPER:-$SNUSNU_REPO_DIR/scripts/stage_initial_root_assets.sh}"
if "$asset_helper" verify >/dev/null 2>&1; then
    mode=already_current
else
    echo 'assets_install=requires_or_creates_uid1000_staging_channel'
    "$asset_helper" install \
        || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE asset_install_failed
    mode=updated
fi
"$asset_helper" verify \
    || stage_fatal "$STAGE_NAME" PRECONDITION_FAILURE asset_hash_verification_failed
echo "assets=$mode"
stage_ok "$STAGE_NAME"
