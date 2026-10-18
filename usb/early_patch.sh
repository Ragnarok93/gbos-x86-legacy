# Sourced from gbos.cfg before mounts; the chroot wrapper runs this at the first dmctl,
# after /new/system and /new/vendor are mounted. Patched libraries are stored in an ext4 image
# with explicit Android SELinux xattrs; never bind executable libraries directly from FAT.
GBOS_PATCH_ROOT=/gbos-patched
GBOS_PATCHED_LIBS_READY=0

gbos_mount_patched_libs() {
  [ -f "$G/patched-libs.img" ] || {
    log "early: patched-libs.img missing; using stock libraries"
    return 1
  }
  mkdir -p "$GBOS_PATCH_ROOT"
  modprobe -q ext4 2>/dev/null || :
  losetup -r /dev/loop15 "$G/patched-libs.img" || {
    log "early: cannot attach patched-libs.img to loop15"
    return 1
  }
  if ! mount -t ext4 -o ro /dev/loop15 "$GBOS_PATCH_ROOT"; then
    losetup -d /dev/loop15 2>/dev/null || :
    log "early: cannot mount patched-libs.img; using stock libraries"
    return 1
  fi
  GBOS_PATCHED_LIBS_READY=1
  log "early: SELinux-labeled patched library image mounted at $GBOS_PATCH_ROOT"
  return 0
}

gbos_early_patch() {
  gbos_mount_patched_libs || return 0

  # init itself contains a SHA-NI SHA-256 routine. The E6540 lacks SHA-NI, so
  # emulating every instruction in init while it loads SELinux policy can take
  # minutes. Use the verified scalar-routed init binary from the labeled ext4
  # sidecar; never execute a replacement directly from the FAT USB filesystem.
  INIT_SRC=$GBOS_PATCH_ROOT/init
  INIT_DST=/new/system/bin/init
  if [ -x "$INIT_SRC" ] && [ -x "$INIT_DST" ]; then
    if mount --bind "$INIT_SRC" "$INIT_DST"; then
      log "early: init SHA-NI SHA-256 path redirected to scalar implementation"
    else
      log "early: init overlay FAILED; stock init remains active"
    fi
  else
    log "early: patched init missing or stock init unavailable; using stock init"
  fi

  # The init overlay is separate from optional library overlays: disabling the
  # libz/libcrypto performance patches must not re-enable init's SHA-NI hot path.
  [ "${GBOS_DISABLE_PATCHED_LIBS:-0}" = 1 ] && {
    log "early: patched libz/libcrypto replacements disabled by config"
    return 0
  }

  for p in system:/new/system/lib64/libz.so:371f70d6a9392327cb36838d0cbc7af7388d1689c25d91cd343af8e58433683b vendor:/new/vendor/lib64/libz.so:e45aecb65cbb40f0c3070b05aa9d974076d401ed6f2aff3081af26a14e812590; do
    n=${p%%:*}; r=${p#*:}; t=${r%%:*}; h=${r#*:}; src="$GBOS_PATCH_ROOT/$n.libz.so"
    if grep -q " $t " /proc/mounts; then
      log "early: $n libz already patched"
    elif [ -f "$src" ] && [ "$(sha256sum "$t" | cut -d' ' -f1)" = "$h" ]; then
      mount --bind "$src" "$t" && log "early: patched $n libz (scalar adler32, SELinux label preserved)" \
        || log "early: bind FAILED for $n libz"
    else
      log "early: $n libz NOT patched (image file missing or original hash mismatch)"
    fi
  done
  for p in system:/new/system/lib64/libcrypto.so:0ee96c7e0cb1ffca5520d2eaca02b4fa2ccff5a8fcb753a491e85555a91c9f2a vendor:/new/vendor/lib64/libcrypto.so:70cc371baf9925d5f1f857d03177d5193caf60bb13bb2012b4336657adcf48e7; do
    n=${p%%:*}; r=${p#*:}; t=${r%%:*}; h=${r#*:}; src="$GBOS_PATCH_ROOT/$n.libcrypto.so"
    if grep -q " $t " /proc/mounts; then
      log "early: $n libcrypto already patched"
    elif [ -f "$src" ] && [ "$(sha256sum "$t" | cut -d' ' -f1)" = "$h" ]; then
      mount --bind "$src" "$t" && log "early: patched $n libcrypto (scalar SHA, SELinux label preserved)" \
        || log "early: bind FAILED for $n libcrypto"
    else
      log "early: $n libcrypto NOT patched (image file missing or original hash mismatch)"
    fi
  done
}

chroot() {
  if [ -z "$GBOS_EARLY_DONE" ] && [ "$1" = /new ]; then
    GBOS_EARLY_DONE=1
    gbos_early_patch
  fi
  command chroot "$@"
}
