#!/usr/bin/env python3 -I
"""Builds deliberately malicious archives for the security test suite.

Usage: make-malicious-fixtures.py OUTPUT_DIR

Every archive here tries to write outside the extraction folder, exhaust resources, or create
dangerous filesystem objects. The test suite asserts that none of them succeed.
"""
import io
import os
import sys
import tarfile
import zipfile
import zlib
import struct

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def p(name):
    return os.path.join(out, name)


# 1. ZIP Slip: relative traversal, absolute path, Windows-style traversal.
with zipfile.ZipFile(p("zip-slip.zip"), "w") as z:
    z.writestr("good.txt", "fine")
    z.writestr("../../escaped-relative.txt", "escaped!")
    z.writestr("/tmp/ua-escaped-absolute.txt", "escaped!")
    zi = zipfile.ZipInfo("..\\..\\escaped-backslash.txt")
    z.writestr(zi, "escaped!")
    z.writestr("dir/../../escaped-mid.txt", "escaped!")

# 2. TAR traversal + absolute.
with tarfile.open(p("tar-slip.tar"), "w", format=tarfile.GNU_FORMAT) as t:
    for name in ["good.txt", "../escaped-tar.txt", "/tmp/ua-escaped-tar-abs.txt", "a/b/../../../escaped-tar2.txt"]:
        data = b"escaped!" if name != "good.txt" else b"fine"
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))

# 3. Symlink escape: link to outside, then write through the link.
with tarfile.open(p("symlink-escape.tar"), "w") as t:
    ti = tarfile.TarInfo("evil-link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "/tmp"
    t.addfile(ti)
    data = b"written through symlink"
    ti = tarfile.TarInfo("evil-link/ua-through-link.txt")
    ti.size = len(data)
    t.addfile(ti, io.BytesIO(data))
    # relative escape
    ti = tarfile.TarInfo("rel-link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "../../.."
    t.addfile(ti)
    ti = tarfile.TarInfo("rel-link/ua-through-rel.txt")
    ti.size = len(data)
    t.addfile(ti, io.BytesIO(data))
    # a safe, internal link that should be preserved
    ti = tarfile.TarInfo("target.txt")
    ti.size = 4
    t.addfile(ti, io.BytesIO(b"real"))
    ti = tarfile.TarInfo("safe-link")
    ti.type = tarfile.SYMTYPE
    ti.linkname = "target.txt"
    t.addfile(ti)

# 4. Symlink in ZIP (Unix external attributes) pointing outside, then file through it.
with zipfile.ZipFile(p("zip-symlink.zip"), "w") as z:
    zi = zipfile.ZipInfo("link")
    zi.create_system = 3
    zi.external_attr = (0o120777 << 16)
    z.writestr(zi, "/etc")
    z.writestr("link/ua-zip-through-link.txt", "escaped!")

# 5. Hard link to a file outside the archive.
with tarfile.open(p("hardlink-escape.tar"), "w") as t:
    ti = tarfile.TarInfo("passwd-link")
    ti.type = tarfile.LNKTYPE
    ti.linkname = "/etc/passwd"
    t.addfile(ti)
    ti = tarfile.TarInfo("dotdot-link")
    ti.type = tarfile.LNKTYPE
    ti.linkname = "../../../etc/hostname"
    t.addfile(ti)

# 6. Device node, FIFO and a setuid executable.
with tarfile.open(p("special-files.tar"), "w") as t:
    ti = tarfile.TarInfo("dev-null-clone")
    ti.type = tarfile.CHRTYPE
    ti.devmajor, ti.devminor = 1, 3
    t.addfile(ti)
    ti = tarfile.TarInfo("a-fifo")
    ti.type = tarfile.FIFOTYPE
    t.addfile(ti)
    data = b"#!/bin/sh\necho hi\n"
    ti = tarfile.TarInfo("suid-script.sh")
    ti.size = len(data)
    ti.mode = 0o4755
    t.addfile(ti, io.BytesIO(data))

# 7. Decompression bomb: one entry of 2 GB of zeros (compresses to ~2 MB), gzip-compressed tar.
#    Written in a streaming way so generating it is cheap.
class Zeros(io.RawIOBase):
    def __init__(self, n):
        self.left = n
    def readable(self):
        return True
    def readinto(self, b):
        n = min(len(b), self.left)
        b[:n] = bytes(n)
        self.left -= n
        return n

BOMB = 2 * 1024 ** 3
with tarfile.open(p("bomb.tar.gz"), "w:gz", compresslevel=9) as t:
    ti = tarfile.TarInfo("zeros.bin")
    ti.size = BOMB
    t.addfile(ti, io.BufferedReader(Zeros(BOMB), 1 << 20))

# 8. Lying ZIP header: declares 10 bytes but the deflate stream produces 50 MB.
raw = zlib.compressobj(9, zlib.DEFLATED, -15)
payload = raw.compress(bytes(50 * 1024 * 1024)) + raw.flush()
name = b"liar.bin"
crc = zlib.crc32(bytes(50 * 1024 * 1024)) & 0xFFFFFFFF
local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 8, 0, 0, crc, len(payload), 10, len(name), 0) + name
cd = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 8, 0, 0, crc, len(payload), 10, len(name), 0, 0, 0, 0, 0, 0) + name
eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(cd), len(local) + len(payload), 0)
with open(p("lying-size.zip"), "wb") as f:
    f.write(local + payload + cd + eocd)

# 9. Many entries (entry-count limit).
with zipfile.ZipFile(p("many-entries.zip"), "w") as z:
    for i in range(5000):
        z.writestr(f"f{i}.txt", "")

# 10. Malformed headers: random garbage with valid signatures.
with open(p("malformed.zip"), "wb") as f:
    f.write(b"PK\x03\x04" + os.urandom(64) + b"PK\x01\x02" + os.urandom(64) + b"PK\x05\x06" + b"\xff" * 18)
with open(p("malformed.7z"), "wb") as f:
    f.write(b"7z\xbc\xaf\x27\x1c\x00\x04" + b"\xff" * 24 + os.urandom(128))
with open(p("malformed.tar.gz"), "wb") as f:
    f.write(b"\x1f\x8b\x08\x00" + os.urandom(200))
with open(p("truncated.tar.xz"), "wb") as f:
    import lzma
    data = lzma.compress(b"x" * 100000)
    f.write(data[: len(data) // 2])

# 11. Oversized declared lengths in tar header (claims 1 PB).
hdr = bytearray(512)
hdr[0:8] = b"huge.bin"
hdr[100:108] = b"0000644\0"
hdr[124:136] = b"\x80" + (10 ** 15).to_bytes(11, "big")  # base-256 size
hdr[136:148] = b"00000000000\0"
hdr[156:157] = b"0"
hdr[257:263] = b"ustar\0"
hdr[263:265] = b"00"
hdr[148:156] = b"        "
chk = sum(hdr)
hdr[148:156] = ("%06o\0 " % chk).encode()
with open(p("huge-declared.tar"), "wb") as f:
    f.write(bytes(hdr) + b"\0" * 1024)

# 12. Recursive archive: zip containing itself-like nesting (zip in zip in zip...).
inner = io.BytesIO()
with zipfile.ZipFile(inner, "w") as z:
    z.writestr("leaf.txt", "leaf")
blob = inner.getvalue()
for depth in range(6):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(f"level{depth}.zip", blob)
    blob = buf.getvalue()
with open(p("nested-deep.zip"), "wb") as f:
    f.write(blob)

# 13. Duplicate names and case-collisions (must not overwrite silently).
with zipfile.ZipFile(p("duplicates.zip"), "w") as z:
    import warnings
    warnings.simplefilter("ignore")
    z.writestr("same.txt", "first")
    z.writestr("same.txt", "second")

# 14. Invalid encryption metadata: encrypted flag set but no encryption header.
with zipfile.ZipFile(p("bad-encryption.zip"), "w") as z:
    z.writestr("x.txt", "hello")
d = bytearray(open(p("bad-encryption.zip"), "rb").read())
d[6] |= 1  # set "encrypted" general purpose bit in local header
cdpos = d.find(b"PK\x01\x02")
d[cdpos + 8] |= 1
open(p("bad-encryption.zip"), "wb").write(bytes(d))

# 15. Corrupt multipart set (7z.001 + a garbage .002).
print("fixtures written to", out)
