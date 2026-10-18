# Sourced from gbos.cfg, before any partition is mounted. stage0's `dmctl create` calls (one per partition, each
# a fresh process that loads libcrypto) run BoringSSL's load-time module hash through SHA-NI, which traps here:
# ~3.7M emulated instructions, ~2 s of boot, all before hook.sh gets to bind the patched libraries. So bind them
# first: this wraps chroot (dmctl's only external command) and does it once, just before the first call.
# Fail-safe: if this never fires, hook.sh does the same binds later. Both are hash-gated on the exact originals.
# Let hook.sh apply the hash-verified scalar libz/libcrypto replacements. The ISA emulator
# remains responsible for unsupported instructions before Android's root is mounted.
gbos_early_patch() { :; }
chroot() {
  if [ -z "$GBOS_EARLY_DONE" ] && [ "$1" = /new ]; then
    GBOS_EARLY_DONE=1
    gbos_early_patch
  fi
  command chroot "$@"
}
