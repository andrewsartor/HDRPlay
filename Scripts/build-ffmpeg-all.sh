#!/bin/bash
set -e

FFMPEG_VERSION="8.0"
MIN_IOS_VERSION="14.0"
MIN_TVOS_VERSION="14.0"
MIN_MACOS_VERSION="11.0"

# Download FFmpeg if needed
if [ ! -d "ffmpeg-${FFMPEG_VERSION}" ]; then
    echo "Downloading FFmpeg..."
    curl -LO "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2"
    tar xjf "ffmpeg-${FFMPEG_VERSION}.tar.bz2"
fi

FFMPEG_DIR="$(pwd)/ffmpeg-${FFMPEG_VERSION}"
OUTPUT_DIR="$(pwd)/Frameworks"

# Common configure flags
COMMON_FLAGS="
    --disable-programs
    --disable-doc
    --disable-static
    --enable-shared
    --disable-asm
    --enable-pic
    --disable-everything
    --enable-protocol=file,http,https,hls,tcp
    --enable-demuxer=matroska,mov,mp4,m4v
    --enable-decoder=hevc,h264
    --enable-parser=h264,hevc
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb
"

# Build function
build_for_platform() {
    local PLATFORM=$1
    local ARCH=$2
    local SDK=$3
    local MIN_VERSION=$4
    local OUTPUT_NAME=$5
    local TARGET_TRIPLE=$6

    echo "Building for ${OUTPUT_NAME} (${ARCH})..."

    cd "${FFMPEG_DIR}"
    make clean 2>/dev/null || true

    local SDK_PATH=$(xcrun -sdk ${SDK} --show-sdk-path)
    local PREFIX="${OUTPUT_DIR}/${OUTPUT_NAME}"

    mkdir -p "${PREFIX}"

    # Use proper target triple for cross-compilation
    local CC_FLAGS="-arch ${ARCH}"
    if [[ -n "${TARGET_TRIPLE}" ]]; then
        CC_FLAGS="${CC_FLAGS} -target ${TARGET_TRIPLE}"
    else
        CC_FLAGS="${CC_FLAGS} -m${PLATFORM}-version-min=${MIN_VERSION}"
    fi

    ./configure \
        --prefix="${PREFIX}" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=${ARCH} \
        --sysroot="${SDK_PATH}" \
        --cc="clang ${CC_FLAGS}" \
        --extra-cflags="${CC_FLAGS}" \
        --extra-ldflags="${CC_FLAGS}" \
        ${COMMON_FLAGS}

    make -j$(sysctl -n hw.ncpu)
    make install

    cd ..
}

# iOS - arm64 (device)
build_for_platform "ios" "arm64" "iphoneos" "${MIN_IOS_VERSION}" "ios-arm64" "arm64-apple-ios${MIN_IOS_VERSION}"

# iOS Simulator - arm64 (M1/M2 Macs)
build_for_platform "ios-simulator" "arm64" "iphonesimulator" "${MIN_IOS_VERSION}" "ios-simulator-arm64" "arm64-apple-ios${MIN_IOS_VERSION}-simulator"

# iOS Simulator - x86_64 (Intel Macs)
build_for_platform "ios-simulator" "x86_64" "iphonesimulator" "${MIN_IOS_VERSION}" "ios-simulator-x86_64" "x86_64-apple-ios${MIN_IOS_VERSION}-simulator"

# tvOS - arm64 (Apple TV device)
build_for_platform "tvos" "arm64" "appletvos" "${MIN_TVOS_VERSION}" "tvos-arm64" "arm64-apple-tvos${MIN_TVOS_VERSION}"

# tvOS Simulator - arm64
build_for_platform "tvos-simulator" "arm64" "appletvsimulator" "${MIN_TVOS_VERSION}" "tvos-simulator-arm64" "arm64-apple-tvos${MIN_TVOS_VERSION}-simulator"

# tvOS Simulator - x86_64
build_for_platform "tvos-simulator" "x86_64" "appletvsimulator" "${MIN_TVOS_VERSION}" "tvos-simulator-x86_64" "x86_64-apple-tvos${MIN_TVOS_VERSION}-simulator"

# macOS - arm64 (Apple Silicon)
build_for_platform "macos" "arm64" "macosx" "${MIN_MACOS_VERSION}" "macos-arm64" ""

# macOS - x86_64 (Intel)
build_for_platform "macos" "x86_64" "macosx" "${MIN_MACOS_VERSION}" "macos-x86_64" ""

echo "✅ All platforms built!"
