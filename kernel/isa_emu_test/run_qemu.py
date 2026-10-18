#!/usr/bin/env python3
"""run_qemu.py KERNEL [CPU] -- boot KERNEL with ./t as /init, print its output."""
import pathlib, subprocess, sys, tempfile


def cpio(files):
    """Build a newc initramfs without importing the unrelated module smoke-test harness."""
    out = bytearray()
    for ino, (name, data, mode, major, minor) in enumerate(files + [('TRAILER!!!', b'', 0, 0, 0)], 1):
        raw = name.encode() + b'\0'
        fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(raw), 0]
        out += b'070701' + b''.join(b'%08x' % n for n in fields) + raw
        out += bytes(-len(out) % 4)
        out += data
        out += bytes(-len(out) % 4)
    return bytes(out)
here = pathlib.Path(__file__).resolve().parent
kernel = sys.argv[1]
cpu = sys.argv[2] if len(sys.argv) > 2 else 'Skylake-Client'
test_bin = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else here / 't'
files = [('dev', b'', 0o40755, 0, 0), ('dev/console', b'', 0o20600, 5, 1), ('init', test_bin.read_bytes(), 0o100755, 0, 0)]
with tempfile.TemporaryDirectory() as tmp:
    rd = pathlib.Path(tmp) / 'rd.cpio'; rd.write_bytes(cpio(files))
    cmd = ['qemu-system-x86_64', '-machine', 'q35', '-cpu', cpu, '-m', '1024', '-smp', '2', '-nographic', '-no-reboot',
           '-nic', 'none', '-kernel', kernel, '-initrd', str(rd), '-append', 'console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=7 rdinit=/init']
    r = subprocess.run(cmd, capture_output=True, text=True, errors='replace', timeout=300)
out = r.stdout + r.stderr
open("last.log","w").write(out); print("\n".join(l for l in out.splitlines() if "warning: TCG" not in l)[-2500:])
