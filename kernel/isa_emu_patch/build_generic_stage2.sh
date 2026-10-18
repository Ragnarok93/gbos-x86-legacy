#!/bin/sh
# Stage 2: build the minimal stage0 initramfs from the newly built, matching kernel modules.
# Run inside gbos-kbuild with -v gbos-ksrc:/build -v <repo>:/host.
set -eu
KVER=$(cat /build/out/include/config/kernel.release)
SRC=/build/modroot_all/lib/modules/$KVER
DST=/build/modroot_ini/lib/modules/$KVER
[ -d "$SRC" ] || { echo "missing full module tree: $SRC (run build_generic.sh first)" >&2; exit 1; }
[ -f /build/ini_modules.txt ] || { echo "missing /build/ini_modules.txt" >&2; exit 1; }
[ -f /host/kernel/out/busybox ] || { echo "missing /host/kernel/out/busybox" >&2; exit 1; }
rm -rf /build/modroot_ini; mkdir -p "$DST"
while read -r m; do
  [ -n "$m" ] || continue
  [ -f "$SRC/$m" ] || { echo "initramfs module missing from build: $m" >&2; exit 1; }
  mkdir -p "$DST/$(dirname "$m")"
  cp "$SRC/$m" "$DST/$m"
done < /build/ini_modules.txt
cp "$SRC/modules.order" "$SRC/modules.builtin" "$SRC/modules.builtin.modinfo" "$DST/" 2>/dev/null || true
depmod -b /build/modroot_ini "$KVER"
echo "initramfs modules: $(find "$DST" -name '*.ko' | wc -l), $(du -sh /build/modroot_ini | cut -f1) (kernel $KVER)"

# Build the initramfs from the exact stage0 script and matching modules, then point the kernel
# config at it. This is the missing link between edits to usb/stage0_init.sh and BOOTX64.EFI.
python3 /host/usb/make_initramfs.py /build/modroot_ini /build/out/gbos_stage0.cpio
/build/src/scripts/config --file /build/out/.config --set-str INITRAMFS_SOURCE /build/out/gbos_stage0.cpio
make -C /build/src O=/build/out ARCH=x86_64 LLVM=/build/inputs/clang-r584948c/bin/ CC=/build/inputs/clang-r584948c/bin/clang-22 olddefconfig >/dev/null
grep -q '^CONFIG_INITRAMFS_SOURCE="/build/out/gbos_stage0.cpio"$' /build/out/.config || {
  echo "CONFIG_INITRAMFS_SOURCE did not resolve to generated stage0 cpio" >&2; exit 1;
}
# The kernel must be rebuilt after the initramfs is generated, otherwise bzImage still contains
# the previous stage0. Fail rather than silently packaging a stale EFI binary.
make -C /build/src O=/build/out ARCH=x86_64 LLVM=/build/inputs/clang-r584948c/bin/ CC=/build/inputs/clang-r584948c/bin/clang-22 -j${JOBS:-$(nproc)} bzImage 2>&1 | tail -n 30
mkdir -p /host/usb/out /host/usb/modules/lib/modules /host/kernel/out
cp /build/out/arch/x86/boot/bzImage /host/kernel/out/bzImage
cp /build/out/arch/x86/boot/bzImage /host/usb/out/BOOTX64.EFI
rm -rf /host/usb/modules/lib/modules/*
cp -a /build/modroot_all/lib/modules/. /host/usb/modules/lib/modules/
printf 'kernel_release=%s\n' "$KVER" > /host/usb/out/kernel-build.manifest
sha256sum /host/usb/../usb/stage0_init.sh /host/kernel/configure_whl.py /host/usb/out/BOOTX64.EFI >> /host/usb/out/kernel-build.manifest
echo "Wrote /host/usb/out/BOOTX64.EFI and matching modules for $KVER"
