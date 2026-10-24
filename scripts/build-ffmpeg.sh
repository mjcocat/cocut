#!/bin/bash
# Builds the small ffmpeg and ffprobe that Cocut carries inside the app (Contents/Helpers), so
# YouTube and Hudl downloads work on a Mac without Homebrew. yt-dlp uses them to put picture and
# sound together and to download and repair streamed video: stream copy only, no encoders, so
# the build is small and LGPL (no GPL or non-free parts).
#
#   scripts/build-ffmpeg.sh <output folder>
#
# On macOS it builds arm64 and x86_64 and joins them into universal binaries; elsewhere it builds
# for this machine (for testing the configuration).
set -euo pipefail

VERSION=7.1.1
SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
OUT="$(mkdir -p "${1:?usage: build-ffmpeg.sh <output folder>}" && cd "$1" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
curl -fsSL -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
if command -v shasum >/dev/null; then SUM="$(shasum -a 256 ffmpeg.tar.xz)"; else SUM="$(sha256sum ffmpeg.tar.xz)"; fi
[[ "${SUM%% *}" == "$SHA256" ]] || { echo "ffmpeg-$VERSION.tar.xz doesn't match its checksum" >&2; exit 1; }
tar xf ffmpeg.tar.xz

# What yt-dlp asks of it: merging video and sound into MP4 (mov/mp4 in and out, WebM/Matroska
# in), downloading HLS over HTTPS when its own downloader can't, and turning MPEG-TS pieces into
# MP4 (mpegts in, the ADTS-to-ASC filter for AAC). ffprobe reads what's in a file.
COMMON=(
  --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-ffplay
  --disable-shared --enable-static --enable-pic
  --enable-ffmpeg --enable-ffprobe --enable-network
  # zlib (part of macOS): some servers send playlists gzip-compressed (Hudl), and MP4s can have
  # compressed headers.
  --enable-zlib
  --enable-protocol=file,pipe,http,https,tcp,tls,crypto,hls,data
  --enable-demuxer=mov,mpegts,hls,aac,h264,hevc,matroska,mp3,flv,ogg,wav
  --enable-muxer=mp4,mov,ipod,mpegts,matroska,webm,adts,null
  --enable-parser=aac,h264,hevc,av1,vp9,opus,mpegaudio
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,null
  --enable-filter=null,anull,aresample,format,aformat,copy,acopy
  # Decoders only so a stream's settings (picture size, sample rate) can be read; nothing is
  # re-encoded.
  --enable-decoder=aac,aac_latm,mp3,opus,h264,hevc
)

build() { # arch-name, extra configure flags...
  local name="$1"; shift
  cp -R "ffmpeg-$VERSION" "src-$name"
  (cd "src-$name" && ./configure --prefix="$WORK/install-$name" "${COMMON[@]}" "$@" >/dev/null \
     && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null \
     && strip ffmpeg ffprobe 2>/dev/null || true)
  test -x "src-$name/ffmpeg" && test -x "src-$name/ffprobe"
}

if [[ "$(uname)" == "Darwin" ]]; then
  # HTTPS through macOS's own Secure Transport, so there's no OpenSSL to carry.
  MAC=(--enable-securetransport --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0)
  build arm64 --arch=arm64 --cc="clang -arch arm64" --enable-cross-compile --target-os=darwin "${MAC[@]}"
  build x86_64 --arch=x86_64 --cc="clang -arch x86_64" --enable-cross-compile --target-os=darwin --disable-x86asm "${MAC[@]}"
  for tool in ffmpeg ffprobe; do
    lipo -create "src-arm64/$tool" "src-x86_64/$tool" -output "$OUT/$tool"
  done
else
  TLS=()
  if pkg-config --exists openssl 2>/dev/null; then TLS=(--enable-openssl); fi
  build native "${TLS[@]}"
  cp src-native/ffmpeg src-native/ffprobe "$OUT/"
fi
chmod +x "$OUT/ffmpeg" "$OUT/ffprobe"
"$OUT/ffmpeg" -hide_banner -version | head -1
ls -l "$OUT"
