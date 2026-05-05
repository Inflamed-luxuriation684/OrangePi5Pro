#!/usr/bin/env bash
# Patch Armbian's build framework to work around the rust-coreutils chroot
# panic on aarch64 hosts whose vendor BSP kernel auxv handling does not
# satisfy rustix.
#
# DEPLOY (lib/functions/rootfs/create-cache.sh):
#   Right after rootfs cache extraction, before the first chroot operation,
#   replace the /usr/bin/* symlinks that point at /lib/cargo/bin/coreutils/*
#   with a small shell shim that routes through qemu-user-static. qemu sets
#   up its own auxv so rustix is happy. /bin/sh itself is not part of uutils
#   so the shim runs natively.
#
# RESTORE (lib/functions/main/rootfs-image.sh):
#   After all chroot operations are done, before the rootfs is unmounted,
#   restore the original /usr/bin/* -> /lib/cargo/bin/coreutils/* symlinks
#   and remove the shim + qemu-aarch64-static. Final image ships clean
#   uutils so there is no qemu emulation overhead at runtime.
#
# Idempotent: re-running is a no-op if the patches are already applied.
# Pass FRAMEWORK_DIR env var to override the default location.
set -euo pipefail

FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/armbian-build/framework}"
cd "$FRAMEWORK_DIR"

deploy_target=lib/functions/rootfs/create-cache.sh
restore_target=lib/functions/main/rootfs-image.sh

deploy_needle='	create_sources_list_and_deploy_repo_key "image-early" "${RELEASE}" "${SDCARD}/"'
restore_needle='	LOG_SECTION="undeploy_qemu_binary_from_chroot_image" do_with_logging undeploy_qemu_binary_from_chroot "${SDCARD}" "image"'

if grep -q 'uutils-qemu-shim' "$deploy_target"; then
    echo "deploy: already patched"
else
    awk -v needle="$deploy_needle" '
        $0 == needle && !done {
            print "\t# --- BEGIN uutils-shim (rust-coreutils chroot panic workaround) ---"
            print "\t# On aarch64 hosts whose kernel auxv handling does not satisfy rustix,"
            print "\t# every uutils binary panics when launched through chroot. Replace the"
            print "\t# /usr/bin/* symlinks pointing at /lib/cargo/bin/coreutils/* with a small"
            print "\t# shell shim that routes through qemu-user-static; qemu provides its own"
            print "\t# auxv so rustix is happy. /bin/sh itself is not uutils so the shim runs"
            print "\t# natively. Reversed in rootfs-image.sh before image creation."
            print "\tdisplay_alert \"Shimming rust-coreutils via qemu-user-static\" \"${SDCARD}\" \"info\""
            print "\tDEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-user-static >/dev/null 2>&1 || true"
            print "\tif [[ -x /usr/bin/qemu-aarch64-static ]]; then"
            print "\t\trun_host_command_logged cp /usr/bin/qemu-aarch64-static \"${SDCARD}/usr/bin/qemu-aarch64-static\""
            print "\t\tcat > \"${SDCARD}/usr/bin/.uutils-qemu-shim\" <<'\''UUTILS_SHIM_EOF'\''"
            print "#!/bin/sh"
            print "arg0=${0##*/}"
            print "exec /usr/bin/qemu-aarch64-static /lib/cargo/bin/coreutils/\"$arg0\" \"$@\""
            print "UUTILS_SHIM_EOF"
            print "\t\tchmod +x \"${SDCARD}/usr/bin/.uutils-qemu-shim\""
            print "\t\twhile IFS= read -r _cmd; do"
            print "\t\t\tln -sfn .uutils-qemu-shim \"${SDCARD}/usr/bin/${_cmd}\""
            print "\t\tdone < <(find \"${SDCARD}/usr/bin/\" -maxdepth 1 -lname \"../lib/cargo/bin/coreutils/*\" -printf \"%f\\n\" 2>/dev/null)"
            print "\telse"
            print "\t\tdisplay_alert \"qemu-aarch64-static not available\" \"build will likely panic in chroot\" \"wrn\""
            print "\tfi"
            print "\t# --- END uutils-shim ---"
            print ""
            done = 1
        }
        { print }
    ' "$deploy_target" > "${deploy_target}.new"

    if ! grep -q 'uutils-qemu-shim' "${deploy_target}.new"; then
        echo "deploy patch failed: needle not matched in ${deploy_target}" >&2
        rm -f "${deploy_target}.new"
        exit 1
    fi
    mv "${deploy_target}.new" "$deploy_target"
    echo "deploy: patched"
fi

if grep -q 'uutils-shim-restore' "$restore_target"; then
    echo "restore: already patched"
else
    awk -v needle="$restore_needle" '
        $0 == needle && !done {
            print "\t# --- BEGIN uutils-shim-restore ---"
            print "\t# Undo the rust-coreutils -> qemu-shim swap so the final image ships the"
            print "\t# original uutils symlinks. Safe here: all chroot operations are done,"
            print "\t# so restored uutils binaries (which would panic in chroot) wont be invoked."
            print "\tif [[ -e \"${SDCARD}/usr/bin/.uutils-qemu-shim\" ]]; then"
            print "\t\tdisplay_alert \"Restoring rust-coreutils symlinks\" \"${SDCARD}\" \"info\""
            print "\t\twhile IFS= read -r _cmd; do"
            print "\t\t\tln -sfn \"../lib/cargo/bin/coreutils/${_cmd}\" \"${SDCARD}/usr/bin/${_cmd}\""
            print "\t\tdone < <(find \"${SDCARD}/usr/bin/\" -maxdepth 1 -lname \".uutils-qemu-shim\" -printf \"%f\\n\" 2>/dev/null)"
            print "\t\trm -f \"${SDCARD}/usr/bin/.uutils-qemu-shim\" \"${SDCARD}/usr/bin/qemu-aarch64-static\""
            print "\tfi"
            print "\t# --- END uutils-shim-restore ---"
            print ""
            done = 1
        }
        { print }
    ' "$restore_target" > "${restore_target}.new"

    if ! grep -q 'uutils-shim-restore' "${restore_target}.new"; then
        echo "restore patch failed: needle not matched in ${restore_target}" >&2
        rm -f "${restore_target}.new"
        exit 1
    fi
    mv "${restore_target}.new" "$restore_target"
    echo "restore: patched"
fi
