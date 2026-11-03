#!/usr/bin/env bash
# Builds interoperability fixtures with independent reference tools (Info-ZIP, 7-Zip, RARLAB rar,
# GNU tar/gzip/bzip2/xz/zstd/lz4/lzip, cpio, ar, dpkg-deb, gcab, lha, arj, arc, xorriso/genisoimage,
# mksquashfs, wimlib, qemu-img, mtools, ntfs-3g, lzop, lrzip, zpaq, uuencode, binhex).
#
# Usage: Scripts/make-interop-fixtures.sh [OUTPUT_DIR]     (default: Fixtures/Interop)
#
# Each fixture is listed in manifest.json with the payload it must contain. Tools that are not
# installed are skipped and recorded as such; the interop tests only claim what was generated.
# Test passwords below are throwaway values for fixtures; passing them as arguments to reference
# tools here is acceptable, Zipper itself never does.
set -uo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/Fixtures/Interop}"
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT" || exit 1
MANIFEST_ENTRIES=()
SKIPPED=()

add() { # file format payload [password] [encoding] [note]
  MANIFEST_ENTRIES+=("$(python3 -c 'import json,sys; a=sys.argv[1:]; print(json.dumps({"file":a[0],"format":a[1],"payload":a[2],"password":a[3] or None,"encoding":a[4] or None,"note":a[5] or None}, ensure_ascii=False))' "$1" "$2" "$3" "${4:-}" "${5:-}" "${6:-}")")
}
have() { command -v "$1" >/dev/null 2>&1 || { SKIPPED+=("$1"); return 1; }; }

# ---- Payloads -------------------------------------------------------------------------------
mkdir -p payload-unicode/payload/docs/中文 payload-unicode/payload/bin payload-simple/simple
P=payload-unicode/payload
printf 'Hello from the reference tools.\n%.0s' {1..40} > "$P/hello.txt"
printf 'سلام دنیا\n' > "$P/docs/فارسی.txt"
printf 'مرحبا بالعالم\n' > "$P/docs/العربية.txt"
printf '你好，世界\n' > "$P/docs/中文/文件.txt"
printf 'こんにちは\n' > "$P/docs/日本語.txt"
printf '안녕하세요\n' > "$P/docs/한국어.txt"
printf 'नमस्ते\n' > "$P/docs/हिन्दी.txt"
printf 'Привет\n' > "$P/docs/Кириллица.txt"
printf 'party\n' > "$P/docs/emoji 🎉.txt"
python3 -c 'import random,sys; r=random.Random(42); sys.stdout.buffer.write(bytes(r.getrandbits(8) for _ in range(8192)))' > "$P/bin/data.bin"
S=payload-simple/simple
printf 'HELLO WORLD\r\n%.0s' {1..30} > "$S/HELLO.TXT"
python3 -c 'import random,sys; r=random.Random(7); sys.stdout.buffer.write(bytes(r.getrandbits(8)%64+32 for _ in range(3000)))' > "$S/DATA.TXT"
SINGLE=payload-single/notes.txt
mkdir -p payload-single
printf 'single stream payload line\n%.0s' {1..500} > "$SINGLE"

mkdir -p zip 7z rar tar streams misc images packages
# ---- ZIP (Info-ZIP) -------------------------------------------------------------------------
if have zip; then
  (cd payload-unicode && zip -qr -X ../zip/infozip-utf8.zip payload) && add zip/infozip-utf8.zip zip unicode
  (cd payload-unicode && zip -qr -X -P zipcrypto-pw ../zip/infozip-zipcrypto.zip payload) && add zip/infozip-zipcrypto.zip zip unicode zipcrypto-pw
  (cd payload-unicode && zip -qr -X -0 ../zip/infozip-store.zip payload) && add zip/infozip-store.zip zip unicode
  python3 -c 'import random,sys; r=random.Random(3); sys.stdout.buffer.write(bytes(r.getrandbits(8) for _ in range(200000)))' > payload-unicode/big.bin
  (cd payload-unicode && zip -q -s 64k ../zip/infozip-split.zip big.bin) && add zip/infozip-split.zip zip "single:big.bin" "" "" "spanned .z01 set"
fi
# Legacy filename encodings written without the UTF-8 flag (Shift-JIS and CP437).
python3 - <<'PY'
import zipfile, struct, zlib
def raw_zip(path, name_bytes, data):
    crc = zlib.crc32(data) & 0xffffffff
    lh = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0x21, crc, len(data), len(data), len(name_bytes), 0) + name_bytes
    cd = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 0, 0, 0x21, crc, len(data), len(data), len(name_bytes), 0, 0, 0, 0, 0, 0) + name_bytes
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(cd), len(lh) + len(data), 0)
    open(path, "wb").write(lh + data + cd + eocd)
raw_zip("zip/legacy-shiftjis.zip", "日本語.txt".encode("cp932"), b"sjis payload\n")
raw_zip("zip/legacy-cp437.zip", "Café.txt".encode("cp437"), b"cp437 payload\n")
PY
add zip/legacy-shiftjis.zip zip "raw:日本語.txt=sjis payload\n" "" CP932 "Shift-JIS names, no UTF-8 flag"
add zip/legacy-cp437.zip zip "raw:Café.txt=cp437 payload\n" "" "" "CP437 names, no UTF-8 flag"

# ---- 7-Zip ----------------------------------------------------------------------------------
if have 7z; then
  (cd payload-unicode && 7z a -bd -y -t7z -m0=LZMA2 ../7z/lzma2.7z payload >/dev/null) && add 7z/lzma2.7z 7z unicode
  (cd payload-unicode && 7z a -bd -y -t7z -m0=PPMd ../7z/ppmd.7z payload >/dev/null) && add 7z/ppmd.7z 7z unicode
  (cd payload-unicode && 7z a -bd -y -t7z -m0=BZip2 ../7z/bzip2.7z payload >/dev/null) && add 7z/bzip2.7z 7z unicode
  (cd payload-unicode && 7z a -bd -y -t7z -ms=off ../7z/nonsolid.7z payload >/dev/null) && add 7z/nonsolid.7z 7z unicode
  (cd payload-unicode && 7z a -bd -y -t7z -pseven-pw ../7z/aes.7z payload >/dev/null) && add 7z/aes.7z 7z unicode seven-pw
  (cd payload-unicode && 7z a -bd -y -t7z -pseven-pw -mhe=on ../7z/aes-headers.7z payload >/dev/null) && add 7z/aes-headers.7z 7z unicode seven-pw "" "encrypted file names"
  (cd payload-unicode && 7z a -bd -y -t7z -mx=0 -v3k ../7z/split.7z payload >/dev/null) && add 7z/split.7z.001 7z unicode "" "" "volumes .001…"
  (cd payload-unicode && 7z a -bd -y -tzip -mem=AES256 -pzip-aes-pw ../zip/7z-aes256.zip payload >/dev/null) && add zip/7z-aes256.zip zip unicode zip-aes-pw
  (cd payload-unicode && 7z a -bd -y -tzip -mem=AES128 -pzip-aes-pw ../zip/7z-aes128.zip payload >/dev/null) && add zip/7z-aes128.zip zip unicode zip-aes-pw
  (cd payload-unicode && 7z a -bd -y -tzip -mm=Deflate64 ../zip/7z-deflate64.zip payload >/dev/null) && add zip/7z-deflate64.zip zip unicode "" "" "Deflate64"
  (cd payload-unicode && 7z a -bd -y -tzip -mm=BZip2 ../zip/7z-bzip2.zip payload >/dev/null) && add zip/7z-bzip2.zip zip unicode
  (cd payload-unicode && 7z a -bd -y -tzip -mm=LZMA ../zip/7z-lzma.zip payload >/dev/null) && add zip/7z-lzma.zip zip unicode
  (cd payload-unicode && 7z a -bd -y -tzip -mm=PPMd ../zip/7z-ppmd.zip payload >/dev/null) && add zip/7z-ppmd.zip zip unicode "" "" "PPMd in ZIP"
  (cd payload-unicode && 7z a -bd -y -twim ../misc/7z.wim payload >/dev/null) && add misc/7z.wim wim unicode
fi

# ---- RAR (RARLAB) ---------------------------------------------------------------------------
if have rar; then
  (cd payload-unicode && rar a -idq -r -ma5 ../rar/rar5.rar payload) && add rar/rar5.rar rar unicode
  (cd payload-unicode && rar a -idq -r -ma4 ../rar/rar4.rar payload) && add rar/rar4.rar rar unicode
  (cd payload-unicode && rar a -idq -r -ma5 -s ../rar/rar5-solid.rar payload) && add rar/rar5-solid.rar rar unicode
  (cd payload-unicode && rar a -idq -r -ma5 -prar-pw ../rar/rar5-enc.rar payload) && add rar/rar5-enc.rar rar unicode rar-pw
  (cd payload-unicode && rar a -idq -r -ma5 -hprar-pw ../rar/rar5-hdrenc.rar payload) && add rar/rar5-hdrenc.rar rar unicode rar-pw "" "encrypted headers"
  (cd payload-unicode && rar a -idq -r -ma4 -prar-pw ../rar/rar4-enc.rar payload) && add rar/rar4-enc.rar rar unicode rar-pw
  (cd payload-unicode && rar a -idq -ma5 -v40k ../rar/multi.rar big.bin) && add rar/multi.part1.rar rar "single:big.bin" "" "" ".partN.rar volumes"
  (cd payload-unicode && rar a -idq -ma4 -vn -v40k ../rar/old.rar big.bin) && add rar/old.rar rar "single:big.bin" "" "" ".rar/.r00 volumes"
fi

# RAR 7 can no longer create RAR 1.5–4.x archives. RAR3/RAR4 fixtures made with WinRAR come from the
# test corpus of the "rarfile" Python project (ISC licence), fetched from PyPI into a cache.
RF_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ua-fixtures"
if [ ! -d "$RF_CACHE/rarfile-4.2" ]; then
  mkdir -p "$RF_CACHE" && (cd "$RF_CACHE" && pip download --no-binary :all: --no-deps rarfile==4.2 -q >/dev/null 2>&1 && tar xzf rarfile-4.2.tar.gz) || true
fi
if [ -d "$RF_CACHE/rarfile-4.2/test/files" ]; then
  mkdir -p rar4 && cp "$RF_CACHE/rarfile-4.2/LICENSE" rar4/LICENSE-rarfile
  for f in rar3-subdirs.rar rar3-solid.rar rar3-symlink-unix.rar rar3-old.rar rar3-old.r00 rar3-old.r01 rar3-vols.part1.rar rar3-vols.part2.rar rar3-vols.part3.rar rar3-comment-psw.rar rar3-comment-hpsw.rar rar202-comment-nopsw.rar; do
    cp "$RF_CACHE/rarfile-4.2/test/files/$f" rar4/ 2>/dev/null
  done
  for f in rar3-subdirs.rar rar3-solid.rar rar3-symlink-unix.rar rar202-comment-nopsw.rar; do add "rar4/$f" rar verify-only "" "" "WinRAR-made RAR 2/3 (rarfile test corpus)"; done
  add rar4/rar3-old.rar rar verify-only "" "" "old-style .rar/.r00/.r01 volumes"
  add rar4/rar3-vols.part1.rar rar verify-only "" "" "RAR3 .partN volumes"
  add rar4/rar3-comment-psw.rar rar verify-only password "" "RAR3 AES-128 encrypted files"
  add rar4/rar3-comment-hpsw.rar rar verify-only password "" "RAR3 encrypted headers"
else
  SKIPPED+=("rarfile-test-corpus")
fi

# ---- TAR + compressors (GNU) ----------------------------------------------------------------
if have tar; then
  tar -C payload-unicode -cf tar/gnu.tar payload && add tar/gnu.tar tar unicode
  tar -C payload-unicode --format=pax -cf tar/pax.tar payload && add tar/pax.tar tar unicode
  tar -C payload-unicode -czf tar/gnu.tar.gz payload && add tar/gnu.tar.gz tar.gz unicode
  tar -C payload-unicode -czf tar/gnu.tgz payload && add tar/gnu.tgz tar.gz unicode
  tar -C payload-unicode -cjf tar/gnu.tar.bz2 payload && add tar/gnu.tar.bz2 tar.bz2 unicode
  tar -C payload-unicode -cJf tar/gnu.tar.xz payload && add tar/gnu.tar.xz tar.xz unicode
  have zstd && tar -C payload-unicode --zstd -cf tar/gnu.tar.zst payload && add tar/gnu.tar.zst tar.zst unicode
  have lz4 && tar -C payload-unicode -cf - payload | lz4 -q > tar/gnu.tar.lz4 && add tar/gnu.tar.lz4 tar.lz4 unicode
  have lzip && tar -C payload-unicode --lzip -cf tar/gnu.tar.lz payload && add tar/gnu.tar.lz tar.lz unicode
  have lzma && tar -C payload-unicode --lzma -cf tar/gnu.tar.lzma payload && add tar/gnu.tar.lzma tar.lzma unicode
  have compress && tar -C payload-unicode -cf - payload | compress -c > tar/gnu.tar.Z && add tar/gnu.tar.Z tar.Z unicode
  have brotli && tar -C payload-unicode -cf - payload | brotli -c > tar/gnu.tar.br && add tar/gnu.tar.br tar.br unicode
fi
# ---- Single streams --------------------------------------------------------------------------
gzip -c "$SINGLE" > streams/notes.txt.gz && add streams/notes.txt.gz gz "single:notes.txt"
bzip2 -c "$SINGLE" > streams/notes.txt.bz2 && add streams/notes.txt.bz2 bz2 "single:notes.txt"
xz -c "$SINGLE" > streams/notes.txt.xz && add streams/notes.txt.xz xz "single:notes.txt"
have zstd && zstd -q -c "$SINGLE" > streams/notes.txt.zst && add streams/notes.txt.zst zst "single:notes.txt"
have lz4 && lz4 -q -c "$SINGLE" > streams/notes.txt.lz4 && add streams/notes.txt.lz4 lz4 "single:notes.txt"
have lzip && lzip -c "$SINGLE" > streams/notes.txt.lz && add streams/notes.txt.lz lz "single:notes.txt"
have lzma && lzma -c "$SINGLE" > streams/notes.txt.lzma && add streams/notes.txt.lzma lzma "single:notes.txt"
have compress && compress -c "$SINGLE" > streams/notes.txt.Z && add streams/notes.txt.Z Z "single:notes.txt"
have brotli && brotli -c "$SINGLE" > streams/notes.txt.br && add streams/notes.txt.br br "single:notes.txt"
have lzop && lzop -q -c "$SINGLE" > streams/notes.txt.lzo && add streams/notes.txt.lzo lzo "single:notes.txt"
have lrzip && lrzip -q -o streams/notes.txt.lrz "$SINGLE" 2>/dev/null && add streams/notes.txt.lrz lrz "single:notes.txt"

# ---- Other containers ------------------------------------------------------------------------
have cpio && (cd payload-unicode && find payload | cpio -o -H newc --quiet > ../misc/newc.cpio) && add misc/newc.cpio cpio unicode
have ar && (cd payload-simple/simple && ar rc ../../misc/simple.a HELLO.TXT DATA.TXT) && add misc/simple.a ar "flat-simple"
if have dpkg-deb; then
  mkdir -p debpkg/DEBIAN debpkg/usr/share/doc/uatest && printf 'Package: uatest\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@example.com>\nDescription: test\n' > debpkg/DEBIAN/control
  cp "$S/HELLO.TXT" debpkg/usr/share/doc/uatest/ && dpkg-deb --root-owner-group -Zxz --build debpkg packages/uatest.deb >/dev/null && add packages/uatest.deb deb "deb"
  rm -rf debpkg
fi
have gcab && (cd payload-simple/simple && gcab -c -z ../../misc/simple.cab HELLO.TXT DATA.TXT) && add misc/simple.cab cab "flat-simple"
# lhasa (the usual "lha") only extracts; jlha creates.
have jlha && (cd payload-simple && jlha a ../misc/simple.lzh simple/HELLO.TXT simple/DATA.TXT >/dev/null 2>&1) && add misc/simple.lzh lha simple
have arj && (cd payload-simple/simple && arj a -y ../../misc/simple.arj HELLO.TXT DATA.TXT >/dev/null) && add misc/simple.arj arj "flat-simple"
have arc && (cd payload-simple/simple && arc a ../../misc/simple.arc HELLO.TXT DATA.TXT >/dev/null) && add misc/simple.arc arc "flat-simple"
have zpaq && (cd payload-simple && zpaq a ../misc/simple.zpaq simple >/dev/null 2>&1) && add misc/simple.zpaq zpaq simple
have uuencode && uuencode notes.txt < "$SINGLE" > misc/notes.uue && add misc/notes.uue uue "single:notes.txt"
if have binhex; then (cd payload-single && binhex notes.txt > ../misc/notes.hqx 2>/dev/null); [ -s misc/notes.hqx ] && add misc/notes.hqx hqx "single:notes.txt" || rm -f misc/notes.hqx; fi
# EPUB/CBZ/JAR made with Info-ZIP following each format's packaging rules.
if have zip; then
  mkdir -p epubsrc/META-INF epubsrc/OEBPS && printf 'application/epub+zip' > epubsrc/mimetype
  printf '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>' > epubsrc/META-INF/container.xml
  printf '<package/>' > epubsrc/OEBPS/content.opf
  (cd epubsrc && zip -q -X -0 ../packages/book.epub mimetype && zip -q -X -r ../packages/book.epub META-INF OEBPS) && add packages/book.epub epub "epub"
  rm -rf epubsrc
  (cd payload-simple/simple && zip -q ../../packages/comic.cbz HELLO.TXT DATA.TXT) && add packages/comic.cbz cbz "flat-simple"
fi

# ---- Disk and filesystem images --------------------------------------------------------------
if have xorriso; then
  xorriso -as mkisofs -quiet -J -R -o images/unicode.iso payload-unicode/payload 2>/dev/null && add images/unicode.iso iso "image-unicode"
fi
have mksquashfs && mksquashfs payload-unicode/payload images/unicode.squashfs -quiet -noappend >/dev/null && add images/unicode.squashfs squashfs "image-unicode"
if have mke2fs; then
  mke2fs -q -t ext4 -d payload-unicode/payload images/unicode.ext4 4M >/dev/null 2>&1 && add images/unicode.ext4 ext "image-unicode"
fi
if have mkfs.fat && have mcopy; then
  dd if=/dev/zero of=images/simple.fat bs=1k count=1440 2>/dev/null && mkfs.fat -n UATEST images/simple.fat >/dev/null && \
    MTOOLS_SKIP_CHECK=1 mcopy -i images/simple.fat "$S/HELLO.TXT" "$S/DATA.TXT" ::/ && add images/simple.fat fat "flat-simple"
  if have qemu-img; then
    qemu-img convert -q -f raw -O vpc images/simple.fat images/simple.vhd && add images/simple.vhd vhd "disk-of:images/simple.fat"
    qemu-img convert -q -f raw -O qcow2 images/simple.fat images/simple.qcow2 && add images/simple.qcow2 qcow2 "disk-of:images/simple.fat"
    qemu-img convert -q -f raw -O vmdk images/simple.fat images/simple.vmdk && add images/simple.vmdk vmdk "disk-of:images/simple.fat"
    qemu-img convert -q -f raw -O vdi images/simple.fat images/simple.vdi && add images/simple.vdi vdi "disk-of:images/simple.fat"
    qemu-img convert -q -f raw -O vhdx images/simple.fat images/simple.vhdx && add images/simple.vhdx vhdx "disk-of:images/simple.fat"
  fi
fi
if have mkntfs && have ntfscp; then
  dd if=/dev/zero of=images/simple.ntfs bs=1M count=8 2>/dev/null && mkntfs -q -F -f images/simple.ntfs >/dev/null 2>&1 && \
    ntfscp -q images/simple.ntfs "$S/HELLO.TXT" HELLO.TXT >/dev/null 2>&1 && ntfscp -q images/simple.ntfs "$S/DATA.TXT" DATA.TXT >/dev/null 2>&1 && \
    add images/simple.ntfs ntfs "flat-simple"
fi
rm -f payload-unicode/big.bin.tmp

# ---- Manifest --------------------------------------------------------------------------------
python3 - "${MANIFEST_ENTRIES[@]}" <<'PY'
import json, sys, subprocess, datetime
entries = [json.loads(a) for a in sys.argv[1:]]
def ver(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip().splitlines()[0][:80]
    except Exception:
        return None
tools = {"7z": ver(["7z", "i"]) , "rar": ver(["rar", "-iver"]), "zip": ver(["zip", "-v"]), "tar": ver(["tar", "--version"])}
json.dump({"generated": datetime.date.today().isoformat(), "tools": tools, "fixtures": entries}, open("manifest.json", "w"), ensure_ascii=False, indent=1)
print(f"{len(entries)} fixtures")
PY
if [ ${#SKIPPED[@]} -gt 0 ]; then echo "skipped (tool missing): ${SKIPPED[*]}"; fi
