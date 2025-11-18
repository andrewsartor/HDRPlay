#!/bin/bash
# Scripts/build-ffmpeg-ios.sh

set -e

FFMPEG_VERSION="8.0"
ARCH="arm64"
MIN_IOS_VERSION="14.0"

echo "Building FFmpeg ${FFMPEG_VERSION} for iOS ${ARCH}"

# Download if needed
if [ ! -d "ffmpeg-${FFMPEG_VERSION}" ]; then
    echo "Downloading FFmpeg..."
    curl -O https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz
    tar xzf ffmpeg-${FFMPEG_VERSION}.tar.gz
fi

cd ffmpeg-${FFMPEG_VERSION}

# Get paths
DEVELOPER=$(xcode-select -print-path)
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
TOOLCHAIN_PATH="${DEVELOPER}/Toolchains/XcodeDefault.xctoolchain"

PREFIX="$PWD/build-ios-${ARCH}"

# Clean previous build
make clean 2>/dev/null || true
rm -rf $PREFIX

# Critical: Set these environment variables
export CC="xcrun -sdk iphoneos clang"
export CXX="xcrun -sdk iphoneos clang++"
export CFLAGS="-arch ${ARCH} -mios-version-min=${MIN_IOS_VERSION} -fembed-bitcode"
export LDFLAGS="-arch ${ARCH} -mios-version-min=${MIN_IOS_VERSION} -fembed-bitcode"

# Configure with proper flags
./configure \
    --prefix=${PREFIX} \
    --enable-cross-compile \
    --target-os=darwin \
    --arch=${ARCH} \
    --cc="clang" \
    --cxx="clang++" \
    --sysroot=${SDK_PATH} \
    --extra-cflags="-arch ${ARCH} -mios-version-min=${MIN_IOS_VERSION}" \
    --extra-ldflags="-arch ${ARCH} -mios-version-min=${MIN_IOS_VERSION} -L${SDK_PATH}/usr/lib -isysroot ${SDK_PATH}" \
    --disable-programs \
    --disable-ffmpeg \
    --disable-ffplay \
    --disable-ffprobe \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --enable-pic \
    --enable-shared \
    --disable-static \
    --pkg-config-flags="--static" \
    --disable-debug \
    --disable-armv5te \
    --disable-armv6 \
    --disable-armv6t2 \
    --disable-everything \
    --enable-protocol=file,http,https,hls,tcp \
    --enable-demuxer=matroska,mov,mp4 \
    --enable-parser=h264,hevc \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb \
    --disable-asm \
    --disable-network \
    --disable-autodetect

# Build
make -j$(sysctl -n hw.ncpu)
make install

echo "✅ Build complete! Libraries are in: ${PREFIX}"
