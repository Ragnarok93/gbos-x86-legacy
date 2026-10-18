#!/usr/bin/env python3
"""run_qemu_bench.py KERNEL CPU BINARY [EXTRA_KERNEL_ARGS]"""
import pathlib
import subprocess
import sys
import tempfile

kernel = pathlib.Path(sys.argv[1])
cpu = sys.argv[2]
binary = pathlib.Path(sys.argv[3])
extra = sys.argv[4] if len(sys.argv) > 4 else ""

def cpio(files):
    out = bytearray()
    entries = files + [('TRAILER!!!', b'', 0, 0, 0)]
    for ino, (name, data, mode, major, minor) in enumerate(entries, 1):
        raw = name.encode() + b'\0'
        fields = [
            ino, mode, 0, 0, 1, 0, len(data), 0, 0,
            major, minor, len(raw), 0
        ]
        out += b'070701' + b''.join(b'%08x' % v for v in fields)
        out += raw
        out += bytes(-len(out) % 4)
        out += data
        out += bytes(-len(out) % 4)
    return bytes(out)

with tempfile.TemporaryDirectory() as tmp:
    rd = pathlib.Path(tmp) / 'initramfs.cpio'
    rd.write_bytes(cpio([
        ('dev', b'', 0o40755, 0, 0),
        ('dev/console', b'', 0o20600, 5, 1),
        ('init', binary.read_bytes(), 0o100755, 0, 0),
    ]))
    append = (
        'console=ttyS0 8250.nr_uarts=1 panic=-1 loglevel=7 rdinit=/init'
    )
    if extra:
        append += ' ' + extra
    cmd = [
        'qemu-system-x86_64', '-machine', 'q35', '-cpu', cpu,
        '-m', '1024', '-smp', '2', '-nographic', '-no-reboot',
        '-nic', 'none', '-kernel', str(kernel),
        '-initrd', str(rd), '-append', append,
    ]
    result = subprocess.run(
        cmd, capture_output=True, text=True,
        errors='replace', timeout=300
    )

output = result.stdout + result.stderr
for line in output.splitlines():
    if 'BENCH' in line or 'isa_emu:' in line or 'Kernel panic' in line:
        print(line)

if result.returncode:
    print("QEMU exit status:", result.returncode)
    sys.exit(result.returncode)
if 'BENCH ' not in output:
    print("ERROR: benchmark result marker not found")
    print('\n'.join(output.splitlines()[-40:]))
    sys.exit(2)
