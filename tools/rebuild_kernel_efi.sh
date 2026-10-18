#!/bin/sh
# Full generic kernel + stage0 + modules rebuild. Run from any directory.
# Requires Docker image gbos-kbuild and volume gbos-ksrc already prepared per AGENTS.md.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${GBOS_KBUILD_IMAGE:-gbos-kbuild}
VOLUME=${GBOS_KERNEL_VOLUME:-gbos-ksrc}
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "Missing Docker image '$IMAGE'." >&2; exit 1;
}
docker volume inspect "$VOLUME" >/dev/null 2>&1 || {
  echo "Missing Docker volume '$VOLUME'." >&2; exit 1;
}
[ -f "$ROOT/kernel/out/busybox" ] || {
  echo "Missing kernel/out/busybox (required to construct stage0 initramfs)." >&2; exit 1;
}
[ -f "$ROOT/lapis/qemu/cpio_tree.py" ] || {
  echo "Missing lapis/qemu/cpio_tree.py (required by usb/make_initramfs.py)." >&2; exit 1;
}
[ -f "$ROOT/kernel/isa_emu_patch/build_generic.sh" ] || exit 1
[ -f "$ROOT/kernel/isa_emu_patch/build_generic_stage2.sh" ] || exit 1

# Stage 1 configures and compiles the kernel and the complete module tree.
docker run --rm --platform linux/amd64 \
  -v "$VOLUME:/build" -v "$ROOT:/host" -v "$ROOT/kernel:/k" \
  "$IMAGE" sh /host/kernel/isa_emu_patch/build_generic.sh

# Stage 2 selects initramfs modules from that same build, regenerates stage0.cpio from the
# current stage0_init.sh, rebuilds bzImage with that cpio embedded, and exports both outputs.
docker run --rm --platform linux/amd64 \
  -v "$VOLUME:/build" -v "$ROOT:/host" -v "$ROOT/kernel:/k" \
  "$IMAGE" sh /host/kernel/isa_emu_patch/build_generic_stage2.sh

# Postconditions are deliberately strict: image creation must never proceed with mismatched bits.
. "$ROOT/usb/out/kernel-build.manifest"
[ -f "$ROOT/usb/modules/lib/modules/$kernel_release/modules.dep" ] || {
  echo "matching modules.dep not exported for $kernel_release" >&2; exit 1;
}
[ "$(sha256sum "$ROOT/usb/stage0_init.sh" | cut -d' ' -f1)" = "$stage0_sha256" ] || {
  echo "stage0 hash mismatch after build" >&2; exit 1;
}
[ "$(sha256sum "$ROOT/kernel/configure_whl.py" | cut -d' ' -f1)" = "$config_sha256" ] || {
  echo "config hash mismatch after build" >&2; exit 1;
}
[ "$(sha256sum "$ROOT/usb/out/BOOTX64.EFI" | cut -d' ' -f1)" = "$efi_sha256" ] || {
  echo "EFI hash mismatch after build" >&2; exit 1;
}
echo "BUILD VERIFIED: kernel=$kernel_release, EFI embeds current stage0, matching modules exported."
echo "Next: tools/make_gbos86_image.sh [OUT_DIR]"
