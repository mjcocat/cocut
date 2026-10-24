# Third-party software in Cocut

## FFmpeg

Cocut includes `ffmpeg` and `ffprobe` from [FFmpeg](https://ffmpeg.org) 7.1.1, in
`Cocut.app/Contents/Helpers`. Cocut runs them (through yt-dlp) to put downloaded video and sound
together and to download and repair streamed video. It doesn't link them.

They're built by `scripts/build-ffmpeg.sh` from the unmodified FFmpeg 7.1.1 source
(<https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz>), with only stream copying, a few demuxers,
muxers, parsers and decoders, and no GPL or non-free parts, so they're licensed under the
[GNU Lesser General Public License, version 2.1 or later](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).
The script shows the exact configuration; running it rebuilds them.

## yt-dlp

Cocut downloads [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense) from its official GitHub
release on first use, checked against the release's published checksums.

## Person re-identification model

OSNet-AIN from [Torchreid](https://github.com/KaiyangZhou/deep-person-reid) (MIT license), converted
to Core ML.
