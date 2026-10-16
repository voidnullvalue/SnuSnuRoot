#!/bin/sh
# Stable top-level CLI. This file only dispatches/orchestrates; stage behavior
# lives under scripts/stages and reusable mechanics under scripts/lib.
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
die() { echo "FATAL: $*" >&2; exit 1; }
command_name="${1:-status}"
[ "$#" -eq 0 ] || shift

case "$command_name" in
    stage-assets|assets)
        exec "$repo_dir/scripts/stages/10-stage-assets.sh" "$@" ;;
    arm-waiter)
        exec "$repo_dir/scripts/stages/20-arm-waiter.sh" "$@" ;;
    carrier)
        exec "$repo_dir/scripts/stages/30-carrier.sh" "$@" ;;
    leak)
        exec "$repo_dir/scripts/stages/40-hwbinder-leak.sh" "$@" ;;
    write)
        exec "$repo_dir/scripts/stages/50-hwbinder-write.sh" "$@" ;;
    root-service)
        exec "$repo_dir/scripts/stages/60-root-handoff.sh" "$@" ;;
    bootstrap-magisk|bootstrap)
        exec "$repo_dir/scripts/stages/70-magisk-bootstrap.sh" "$@" ;;
    install-persistence|arm|install)
        exec "$repo_dir/scripts/stages/80-install-persistence.sh" "$@" ;;
    firmware)
        SNUSNU_REPO_DIR="$repo_dir" STAGE_NAME=firmware
        . "$repo_dir/scripts/lib/common.sh"
        . "$repo_dir/scripts/firmware_compat.sh"
        require_device
        snusnu_firmware_report "$repo_dir/firmware/manifest.psv" ;;
    root)
        exec "$repo_dir/scripts/root_flow.sh" "$@" ;;
    status)
        exec "$repo_dir/scripts/stages/status.sh" "$@" ;;
    doctor)
        exec "$repo_dir/scripts/persistence_driver.sh" doctor "$@" ;;
    disarm)
        "$repo_dir/scripts/persistence_driver.sh" disarm "$@"
        SNUSNU_REPO_DIR="$repo_dir" . "$repo_dir/scripts/lib/common.sh"
        . "$repo_dir/scripts/lib/state.sh"
        state_clear_all
        echo 'stage_state=cleared'
        ;;
    manager)
        exec "$repo_dir/scripts/snusnu_magisk_manager.sh" setup "$@" ;;
    request)
        exec "$repo_dir/scripts/snusnu_magisk_manager.sh" request "$@" ;;
    verify)
        exec "$repo_dir/scripts/persistence_driver.sh" verify "$@" ;;
    *)
        die "usage: $0 {firmware|stage-assets|arm-waiter|carrier|leak|write|root-service|bootstrap-magisk|install-persistence|manager|status|doctor|disarm|root}"
        ;;
esac
