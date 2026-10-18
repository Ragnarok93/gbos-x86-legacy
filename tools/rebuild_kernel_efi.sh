#!/bin/sh
# Full generic kernel + stage0 + modules rebuild. Run from any directory.
# Requires Docker image gbos-kbuild and volume gbos-ksrc prepared per AGENTS.md.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${GBOS_KBUILD_IMAGE:-gbos-kbuild}
VOLUME=${GBOS_KERNEL_VOLUME:-gbos-ksrc}
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "Missing Docker image '$IMAGE'." >&2; exit 1; }
docker volume inspect "$VOLUME" >/dev/null 2>&1 || { echo "Missing Docker volume '$VOLUME'." >&2; exit 1; }
[ -f "$ROOT/kernel/out/busybox" ] || { echo "Missing kernel/out/busybox." >&2; exit 1; }
[ -f "$ROOT/lapis/qemu/cpio_tree.py" ] || { echo "Missing lapis/qemu/cpio_tree.py." >&2; exit 1; }

# Stage 1: compile kernel and full module tree.
docker run --rm --platform linux/amd64 -v "$VOLUME:/build" -v "$ROOT:/host" -v "$ROOT/kernel:/k" \
  "$IMAGE" sh /host/kernel/isa_emu_patch/build_generic.sh
# Stage 2: regenerate stage0 from current sources, rebuild EFI with it embedded, export matching modules.
docker run --rm --platform linux/amd64 -v "$VOLUME:/build" -v "$ROOT:/host" -v "$ROOT/kernel:/k" \
  "$IMAGE" sh /host/kernel/isa_emu_patch/build_generic_stage2.sh

. "$ROOT/usb/out/kernel-build.manifest"
[ -f "$ROOT/usb/modules/lib/modules/$kernel_release/modules.dep" ] || { echo "matching modules.dep not exported." >&2; exit 1; }
[ "$(sha256sum "$ROOT/usb/stage0_init.sh" | cut -d' ' -f1)" = "$stage0_sha256" ] || { echo "stage0 hash mismatch." >&2; exit 1; }
[ "$(sha256sum "$ROOT/kernel/configure_whl.py" | cut -d' ' -f1)" = "$config_sha256" ] || { echo "config hash mismatch." >&2; exit 1; }
[ "$(sha256sum "$ROOT/usb/out/BOOTX64.EFI" | cut -d' ' -f1)" = "$efi_sha256" ] || { echo "EFI hash mismatch." >&2; exit 1; }
echo "BUILD VERIFIED: kernel=$kernel_release; EFI embeds current stage0; matching modules exported."
echo "Next: tools/make_gbos86_image.sh [OUT_DIR]"
