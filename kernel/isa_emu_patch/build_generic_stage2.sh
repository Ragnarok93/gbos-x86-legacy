#!/bin/sh
# Stage 2: build the minimal stage0 initramfs from the newly built, matching kernel modules.
# Run inside gbos-kbuild with -v gbos-ksrc:/build -v <repo>:/host.
set -eu
KVER=$(cat /build/out/include/config/kernel.release)
SRC=/build/modroot_all/lib/modules/$KVER
DST=/build/modroot_ini/lib/modules/$KVER
MODULE_LIST=/host/kernel/isa_emu_patch/initramfs_modules.txt
[ -d "$SRC" ] || { echo "missing full module tree: $SRC (run build_generic.sh first)" >&2; exit 1; }
[ -f "$MODULE_LIST" ] || { echo "missing version-controlled module list: $MODULE_LIST" >&2; exit 1; }
[ -f /host/kernel/out/busybox ] || { echo "missing /host/kernel/out/busybox" >&2; exit 1; }

# Resolve each required module against this exact build and copy its complete dependency closure.
# Keeping the root module names in git avoids relying on an undocumented file in the Docker volume.
rm -rf /build/modroot_ini
mkdir -p "$DST"
DEPS_LOG=/build/out/initramfs-module-deps.log
: > "$DEPS_LOG"
while IFS= read -r module || [ -n "$module" ]; do
  case "$module" in ''|'#'*) continue;; esac
  if ! modprobe --dirname /build/modroot_all --set-version "$KVER" --show-depends "$module" >> "$DEPS_LOG"; then
    echo "cannot resolve required initramfs module: $module" >&2
    exit 1
  fi
done < "$MODULE_LIST"

copied=0
while read -r action path rest; do
  [ "$action" = insmod ] || continue
  case "$path" in
    "$SRC"/*) rel=${path#"$SRC"/} ;;
    *) echo "unexpected module path from modprobe: $path" >&2; exit 1 ;;
  esac
  [ -f "$path" ] || { echo "resolved module file missing: $path" >&2; exit 1; }
  mkdir -p "$DST/$(dirname "$rel")"
  cp -f "$path" "$DST/$rel"
  copied=$((copied + 1))
done < "$DEPS_LOG"
[ "$copied" -gt 0 ] || { echo "module resolver produced no loadable initramfs modules" >&2; exit 1; }

depmod -b /build/modroot_ini "$KVER"
echo "initramfs modules: $(find "$DST" -name '*.ko*' | wc -l), $(du -sh /build/modroot_ini | cut -f1) (kernel $KVER)"

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
if ! make -C /build/src O=/build/out ARCH=x86_64 LLVM=/build/inputs/clang-r584948c/bin/ CC=/build/inputs/clang-r584948c/bin/clang-22 -j${JOBS:-$(nproc)} bzImage > /build/out/build-stage0.log 2>&1; then
  tail -n 80 /build/out/build-stage0.log
  exit 1
fi
tail -n 30 /build/out/build-stage0.log
mkdir -p /host/usb/out /host/usb/modules/lib/modules /host/kernel/out
cp /build/out/arch/x86/boot/bzImage /host/kernel/out/bzImage
cp /build/out/arch/x86/boot/bzImage /host/usb/out/BOOTX64.EFI
rm -rf /host/usb/modules/lib/modules/*
cp -a /build/modroot_all/lib/modules/. /host/usb/modules/lib/modules/
{
  printf 'kernel_release=%s\\n' "$KVER"
  printf 'stage0_sha256=%s\\n' "$(sha256sum /host/usb/stage0_init.sh | cut -d' ' -f1)"
  printf 'config_sha256=%s\\n' "$(sha256sum /host/kernel/configure_whl.py | cut -d' ' -f1)"
  printf 'efi_sha256=%s\\n' "$(sha256sum /host/usb/out/BOOTX64.EFI | cut -d' ' -f1)"
} > /host/usb/out/kernel-build.manifest
echo "Wrote /host/usb/out/BOOTX64.EFI and matching modules for $KVER"
