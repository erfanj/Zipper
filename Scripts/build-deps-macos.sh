#!/usr/bin/env bash
# Builds the C dependencies as static, Apple-Silicon-native (optionally universal) libraries so the
# shipped app does not depend on Homebrew. Every download is pinned by SHA-256.
#
#   Scripts/build-deps-macos.sh [--universal]
#
# Output: Vendor/macos/{include,lib,lib/pkgconfig} and Vendor/macos/helpers/7zz.
# Then build with: PKG_CONFIG_PATH="$PWD/Vendor/macos/lib/pkgconfig" swift build -c release
#
# libarchive is configured to use Apple's CommonCrypto (for ZIP AES/HMAC/PBKDF2), iconv and libxml2
# from the SDK, and the static xz/zstd/lz4 built here; zlib and bzip2 come from the SDK.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PREFIX="$ROOT/Vendor/macos"
SRC="$ROOT/Vendor/src"
ARCHS="arm64"
[[ "${1:-}" == "--universal" ]] && ARCHS="arm64 x86_64"
MIN_MACOS=14.0
mkdir -p "$PREFIX" "$SRC"

fetch() { # url file sha256
  local url=$1 file=$2 sum=$3
  if [[ ! -f "$SRC/$file" ]]; then curl -fL --retry 3 -o "$SRC/$file" "$url"; fi
  echo "$sum  $SRC/$file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $file"; exit 1; }
}

fetch https://github.com/libarchive/libarchive/releases/download/v3.8.9/libarchive-3.8.9.tar.xz libarchive-3.8.9.tar.xz 888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde
fetch https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.xz xz-5.8.4.tar.xz 4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b
fetch https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz zstd-1.5.7.tar.gz eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
fetch https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz lz4-1.10.0.tar.gz 537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
# Brotli's C sources, taken from the official PyPI source distribution (same code as the GitHub tag).
fetch https://files.pythonhosted.org/packages/source/b/brotli/brotli-1.2.0.tar.gz brotli-1.2.0.tar.gz e310f77e41941c13340a95976fe66a8a95b01e783d430eeaf7a2f87e0a57dd0a
# Official 7-Zip console build for macOS (universal arm64/x86_64), bundled as a helper process.
fetch https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz 7z2604-mac.tar.xz bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578

ARCHFLAGS=""
for a in $ARCHS; do ARCHFLAGS="$ARCHFLAGS -arch $a"; done
export CFLAGS="$ARCHFLAGS -mmacosx-version-min=$MIN_MACOS -O2 -fPIC"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$ARCHFLAGS -mmacosx-version-min=$MIN_MACOS"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
JOBS=$(sysctl -n hw.ncpu)
B="$ROOT/Vendor/build"
rm -rf "$B"; mkdir -p "$B"

# xz (liblzma)
tar -xJf "$SRC/xz-5.8.4.tar.xz" -C "$B"
(cd "$B/xz-5.8.4" && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

# zstd
tar -xzf "$SRC/zstd-1.5.7.tar.gz" -C "$B"
(cd "$B/zstd-1.5.7/lib" && make -j"$JOBS" libzstd.a ZSTD_LIB_MINIFY=0 >/dev/null && make install-static install-includes install-pc PREFIX="$PREFIX" >/dev/null)

# lz4
tar -xzf "$SRC/lz4-1.10.0.tar.gz" -C "$B"
(cd "$B/lz4-1.10.0/lib" && make -j"$JOBS" liblz4.a >/dev/null && make install PREFIX="$PREFIX" BUILD_SHARED=no >/dev/null)

# brotli (compiled directly; no CMake needed)
tar -xzf "$SRC/brotli-1.2.0.tar.gz" -C "$B"
(
  cd "$B/brotli-1.2.0/c"
  mkdir -p obj
  for f in common/*.c dec/*.c enc/*.c; do clang $CFLAGS -Iinclude -c "$f" -o "obj/$(echo "$f" | tr '/' '_').o"; done
  ar rcs "$PREFIX/lib/libbrotlicommon.a" obj/common_*.o
  ar rcs "$PREFIX/lib/libbrotlidec.a" obj/dec_*.o
  ar rcs "$PREFIX/lib/libbrotlienc.a" obj/enc_*.o
  mkdir -p "$PREFIX/include/brotli" && cp include/brotli/*.h "$PREFIX/include/brotli/"
  cat > "$PREFIX/lib/pkgconfig/libbrotlienc.pc" <<PC
prefix=$PREFIX
Name: libbrotlienc
Description: Brotli encoder (static)
Version: 1.2.0
Libs: -L\${prefix}/lib -lbrotlienc -lbrotlidec -lbrotlicommon
Cflags: -I\${prefix}/include
PC
)

# libarchive
tar -xJf "$SRC/libarchive-3.8.9.tar.xz" -C "$B"
(
  cd "$B/libarchive-3.8.9"
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --without-openssl --without-nettle --without-mbedtls \
    --without-lzo2 --without-cng --with-lzma --with-zstd --with-lz4 --with-bz2lib --with-zlib --with-iconv --with-xml2 \
    --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip --disable-acl \
    CPPFLAGS="-I$PREFIX/include" LDFLAGS="$LDFLAGS -L$PREFIX/lib" >/dev/null
  make -j"$JOBS" >/dev/null && make install >/dev/null
)
# Static link line for consumers (SwiftPM reads Libs.private only with --static, so fold it in).
sed -i '' -e "s|^Libs:.*|Libs: -L$PREFIX/lib -larchive -llzma -lzstd -llz4 -lbz2 -lz -liconv -lxml2|" "$PREFIX/lib/pkgconfig/libarchive.pc"

# 7-Zip helper
mkdir -p "$PREFIX/helpers"
tar -xJf "$SRC/7z2604-mac.tar.xz" -C "$PREFIX/helpers" 7zz License.txt
mv "$PREFIX/helpers/License.txt" "$PREFIX/helpers/7-Zip-License.txt"

echo "Dependencies installed in $PREFIX"
echo "Build with: PKG_CONFIG_PATH=\"$PREFIX/lib/pkgconfig\" swift build -c release --arch arm64"
