#!/bin/sh
# make_gbos86_image.sh [OUT_DIR]: build a flashable gbOS86 USB image (live + installer).
#
#   OUT_DIR/gbOS86-YYYYMMDD.img (+ .sha256), ~6.3 GiB, GPT:
#     p1  EFI   256 MiB FAT32  EFI/BOOT/BOOTX64.EFI (kernel + stage0 with the gbOS86 boot menu)
#     p2  GBOS    6 GiB FAT32  /gbos: super.img, hook.sh, install.sh, firmware, patches, ... (+ logs)
#
# Write it to any USB stick of 8 GB or more (balenaEtcher, Rufus, or dd). Booting it shows the
# gbOS86 menu: live / install-or-update / boot the installed system.
#
# Needs: docker, python3, and Google's extracted partitions in lapis/parts/*_a.img (see README).
# The image contains Google's OS and patched Google libraries: for your own use, don't share it.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/dist}
U=$ROOT/usb
P=$ROOT/lapis/parts
NAME=gbOS86-$(date +%Y%m%d)

# This locally generated binary has its SHA-NI SHA-256 entry redirected to the
# scalar implementation by tools/patch_init_sha.py. It is intentionally not
# tracked because it is derived from Google's proprietary system image.
PATCHED_INIT=$ROOT/lapis/patched/init
PATCHED_INIT_SHA=$PATCHED_INIT.orig.sha256
[ -s "$PATCHED_INIT" ] && [ -s "$PATCHED_INIT_SHA" ] || {
  echo "missing patched init or source-hash manifest ($PATCHED_INIT and $PATCHED_INIT_SHA)." >&2
  echo "Regenerate both with: python3 tools/patch_init_sha.py <matching stock /system/bin/init> $PATCHED_INIT" >&2
  exit 1
}
case "$(cat "$PATCHED_INIT_SHA")" in
  *[!0-9a-f]*|'') echo "invalid init source-hash manifest: $PATCHED_INIT_SHA" >&2; exit 1 ;;
esac
[ "$(wc -c < "$PATCHED_INIT_SHA")" -eq 65 ] || {
  echo "init source-hash manifest must contain exactly 64 hex digits and a newline" >&2; exit 1;
}

# Never build an image from a stale EFI or a module tree from another kernel build.
MANIFEST=$U/out/kernel-build.manifest
[ -f "$MANIFEST" ] || { echo "missing $MANIFEST; run tools/rebuild_kernel_efi.sh first" >&2; exit 1; }
. "$MANIFEST"
[ -n "${kernel_release:-}" ] && [ -n "${stage0_sha256:-}" ] && [ -n "${config_sha256:-}" ] && [ -n "${efi_sha256:-}" ] || {
  echo "invalid kernel build manifest: $MANIFEST" >&2; exit 1;
}
[ "$(sha256sum "$U/stage0_init.sh" | cut -d' ' -f1)" = "$stage0_sha256" ] || {
  echo "stage0_init.sh changed after kernel build; run tools/rebuild_kernel_efi.sh" >&2; exit 1;
}
[ "$(sha256sum "$ROOT/kernel/configure_whl.py" | cut -d' ' -f1)" = "$config_sha256" ] || {
  echo "configure_whl.py changed after kernel build; run tools/rebuild_kernel_efi.sh" >&2; exit 1;
}
[ "$(sha256sum "$U/out/BOOTX64.EFI" | cut -d' ' -f1)" = "$efi_sha256" ] || {
  echo "BOOTX64.EFI does not match build manifest; run tools/rebuild_kernel_efi.sh" >&2; exit 1;
}
[ -f "$U/modules/lib/modules/$kernel_release/modules.dep" ] || {
  echo "matching module tree missing for $kernel_release; run tools/rebuild_kernel_efi.sh" >&2; exit 1;
}
STAGE=$OUT/$NAME.stage
mkdir -p "$OUT"; rm -rf "$STAGE"; mkdir -p "$STAGE/efi/EFI/BOOT" "$STAGE/gbos/gbos"

# 1. System: super.img from Google's partitions (same bytes the stick/NVMe installs were made from)
for n in system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a; do
  [ -f "$P/$n.img" ] || { echo "missing $P/$n.img"; exit 1; }
done
echo "== super.img"
python3 "$U/make_super.py" "$STAGE/gbos/gbos/super.img" "$STAGE/gbos/gbos/super.layout" \
  system_a="$P/system_a.img" vendor_a="$P/vendor_a.img" product_a="$P/product_a.img" \
  system_ext_a="$P/system_ext_a.img" system_dlkm_a="$P/system_dlkm_a.img" vendor_dlkm_a="$P/vendor_dlkm_a.img"

# 2. Everything else stage0/hook/install expect on the stick
echo "== files"
cp "$U/out/BOOTX64.EFI" "$STAGE/efi/EFI/BOOT/BOOTX64.EFI"
G=$STAGE/gbos/gbos
for f in hook.sh aidiag.sh early_patch.sh hwdetect.sh install.sh apex_patch.sh gbos.cfg crossystem bootdisk.img libkm_compat.so system_ext_manifest.xml soft_gk; do
  cp "$U/$f" "$G/$f"
done
for d in firmware patched audio installer kmod modules; do cp -R "$U/$d" "$G/$d"; done
# Kernel build/source symlinks are compile-time only and cannot be represented in the FAT image.
find "$G/modules" -type l \( -name build -o -name source \) -delete

# Build a tiny ext4 sidecar for performance-only library overlays. Unlike FAT, ext4 can carry
# Android security.selinux xattrs, so bind-mounted libraries keep their expected labels after init
# switches SELinux to enforcing. Never source these shared libraries directly from vfat.
PATCHROOT=$STAGE/patched-libs-root
mkdir -p "$PATCHROOT"
for f in system.libz.so vendor.libz.so system.libcrypto.so vendor.libcrypto.so; do
  [ -s "$U/patched/$f" ] || { echo "missing patched library: $U/patched/$f" >&2; exit 1; }
  cp "$U/patched/$f" "$PATCHROOT/$f"
done
cp "$PATCHED_INIT" "$PATCHROOT/init"
cp "$PATCHED_INIT_SHA" "$PATCHROOT/init.orig.sha256"
chmod 0755 "$PATCHROOT/init"
docker run --rm --platform linux/amd64 -v "$STAGE":/o alpine:latest sh -c '
set -eu
apk add -q e2fsprogs e2fsprogs-extra >/dev/null
img=/o/gbos/gbos/patched-libs.img
truncate -s 32M "$img"
mke2fs -q -t ext4 -F -d /o/patched-libs-root "$img"
debugfs -w -R "ea_set /init security.selinux u:object_r:init_exec:s0" "$img" >/dev/null
debugfs -R "ea_list /init" "$img" | grep -F "init_exec" >/dev/null
debugfs -w -R "ea_set /system.libz.so security.selinux u:object_r:system_lib_file:s0" "$img" >/dev/null
debugfs -w -R "ea_set /system.libcrypto.so security.selinux u:object_r:system_lib_file:s0" "$img" >/dev/null
debugfs -w -R "ea_set /vendor.libz.so security.selinux u:object_r:vendor_file:s0" "$img" >/dev/null
debugfs -w -R "ea_set /vendor.libcrypto.so security.selinux u:object_r:vendor_file:s0" "$img" >/dev/null
debugfs -R "ea_list /system.libz.so" "$img" | grep -F "system_lib_file" >/dev/null
debugfs -R "ea_list /system.libcrypto.so" "$img" | grep -F "system_lib_file" >/dev/null
debugfs -R "ea_list /vendor.libz.so" "$img" | grep -F "vendor_file" >/dev/null
debugfs -R "ea_list /vendor.libcrypto.so" "$img" | grep -F "vendor_file" >/dev/null
'
rm -rf "$PATCHROOT"
mkdir -p "$G/logs"
# gbos.cfg ships with MODE=ask (the boot menu)
grep -q '^MODE=ask$' "$G/gbos.cfg" || { echo "usb/gbos.cfg must have MODE=ask for the image"; exit 1; }
cp "$ROOT/kernel/out/busybox" "$STAGE/gbos/busybox"
mkdir -p "$STAGE/gbos/EFI/BOOT" && cp "$U/out/BOOTX64.EFI" "$STAGE/gbos/EFI/BOOT/BOOTX64.EFI"
cat > "$STAGE/gbos/README.txt" <<'EOF'
gbOS86: Googlebook OS on x86 laptops (Intel 6th gen+; boot-time hardware detection; tested: Dell Latitude 5300, i5-8365U).
Boot this USB (F12 at the Dell logo) for the gbOS86 menu:
  1) live from USB   2) install or update on the internal SSD   3) boot the installed system
Settings: gbos/gbos.cfg (MODE, DENSITY, RESOLUTION, HWDETECT ...). Logs: gbos/logs/boot-N/ (hwdetect.txt = what was detected).
EOF
du -sh "$STAGE/gbos/gbos/super.img" "$STAGE/gbos"

# 3. Assemble the GPT image (FAT32 partitions built as files, then placed at their offsets)
echo "== image"
IMG=$OUT/$NAME.img
# Fedora/RHEL (SELinux enforcing): the bind mount needs :z; relabel only when OUT is inside this repo (default dist/).
Z=; if [ "$(getenforce 2>/dev/null)" = Enforcing ]; then case $OUT in "$ROOT"/*) Z=:z;; esac; fi
docker run --rm --platform linux/amd64 -v "$OUT":/o$Z alpine:latest sh -c '
set -e
apk add -q mtools dosfstools sfdisk coreutils >/dev/null
cd /o; S='"$NAME"'.stage
EFI_MB=256; GBOS_MB=6144
rm -f p1.fat p2.fat
truncate -s ${EFI_MB}M p1.fat;  mkfs.fat -F 32 -n EFI  p1.fat >/dev/null; mcopy -s -i p1.fat $S/efi/EFI ::/
truncate -s ${GBOS_MB}M p2.fat; mkfs.fat -F 32 -n GBOS p2.fat >/dev/null; mcopy -s -i p2.fat $S/gbos/* ::/
rm -f '"$NAME"'.img; truncate -s $(( (EFI_MB + GBOS_MB + 2) * 1048576 )) '"$NAME"'.img
printf "label: gpt\nstart=2048, size=$((EFI_MB*2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"gbOS86 EFI\"\nsize=$((GBOS_MB*2048)), type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"gbOS86\"\n" | sfdisk -q '"$NAME"'.img
dd if=p1.fat of='"$NAME"'.img bs=1M seek=1 conv=notrunc,sparse status=none
dd if=p2.fat of='"$NAME"'.img bs=1M seek=$((1 + EFI_MB)) conv=notrunc,sparse status=none
rm -f p1.fat p2.fat
sfdisk -l '"$NAME"'.img | tail -3
mdir -i '"$NAME"'.img@@$((1048576*(1+EFI_MB))) ::/gbos | head -25'
rm -rf "$STAGE"
(cd "$OUT" && shasum -a 256 "$NAME.img" > "$NAME.img.sha256" && cat "$NAME.img.sha256")
ls -la "$IMG"
echo "Write $IMG to a USB stick (8 GB+) with balenaEtcher/Rufus, or: sudo dd if=$IMG of=/dev/rdiskN bs=4m"
