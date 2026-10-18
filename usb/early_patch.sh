# Sourced from gbos.cfg after /new/system and /new/vendor are mounted, before the first dmctl.
# dmctl loads libcrypto in a fresh process; the unpatched SHA-NI path is very expensive on CPUs
# without SHA-NI. Bind only replacements made for the exact original bytes; hook.sh repeats this
# check later as a fail-safe and handles the Conscrypt APEX after apexd activation.
gbos_early_patch() {
  for p in system:/new/system/lib64/libz.so:371f70d6a9392327cb36838d0cbc7af7388d1689c25d91cd343af8e58433683b vendor:/new/vendor/lib64/libz.so:e45aecb65cbb40f0c3070b05aa9d974076d401ed6f2aff3081af26a14e812590; do
    n=${p%%:*}; r=${p#*:}; t=${r%%:*}; h=${r#*:}
    if grep -q " $t " /proc/mounts; then
      log "early: $n libz already patched"
    elif [ -f "$G/patched/$n.libz.so" ] && [ "$(sha256sum "$t" | cut -d' ' -f1)" = "$h" ]; then
      mount --bind "$G/patched/$n.libz.so" "$t" && log "early: patched $n libz (scalar adler32) active" \
        || log "early: bind FAILED for $n libz"
    else
      log "early: $n libz NOT patched (missing replacement or original hash mismatch)"
    fi
  done
  for p in system:/new/system/lib64/libcrypto.so:0ee96c7e0cb1ffca5520d2eaca02b4fa2ccff5a8fcb753a491e85555a91c9f2a vendor:/new/vendor/lib64/libcrypto.so:70cc371baf9925d5f1f857d03177d5193caf60bb13bb2012b4336657adcf48e7; do
    n=${p%%:*}; r=${p#*:}; t=${r%%:*}; h=${r#*:}
    if grep -q " $t " /proc/mounts; then
      log "early: $n libcrypto already patched"
    elif [ -f "$G/patched/$n.libcrypto.so" ] && [ "$(sha256sum "$t" | cut -d' ' -f1)" = "$h" ]; then
      mount --bind "$G/patched/$n.libcrypto.so" "$t" && log "early: patched $n libcrypto (scalar SHA) active" \
        || log "early: bind FAILED for $n libcrypto"
    else
      log "early: $n libcrypto NOT patched (missing replacement or original hash mismatch)"
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
