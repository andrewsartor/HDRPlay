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
    
    echo "Building for ${PLATFORM} ${ARCH}..."
    
    cd "${FFMPEG_DIR}"
    make clean 2>/dev/null || true
    
    local SDK_PATH=$(xcrun -sdk ${SDK} --show-sdk-path)
    local PREFIX="${OUTPUT_DIR}/${OUTPUT_NAME}-${ARCH}"
    
    mkdir -p "${PREFIX}"
    
    ./configure \
        --prefix="${PREFIX}" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch=${ARCH} \
        --sysroot="${SDK_PATH}" \
        --cc="clang -arch ${ARCH}" \
        --extra-cflags="-m${PLATFORM}-version-min=${MIN_VERSION}" \
        --extra-ldflags="-m${PLATFORM}-version-min=${MIN_VERSION}" \
        ${COMMON_FLAGS}
    
    make -j$(sysctl -n hw.ncpu)
    make install
    
    cd ..
}

# iOS - arm64 (device)
build_for_platform "ios" "arm64" "iphoneos" "${MIN_IOS_VERSION}" "ios"

# iOS Simulator - arm64 (M1/M2 Macs)
build_for_platform "ios-simulator" "arm64" "iphonesimulator" "${MIN_IOS_VERSION}" "ios-simulator"

# iOS Simulator - x86_64 (Intel Macs)
build_for_platform "ios-simulator" "x86_64" "iphonesimulator" "${MIN_IOS_VERSION}" "ios-simulator"

# tvOS - arm64 (Apple TV device)
build_for_platform "tvos" "arm64" "appletvos" "${MIN_TVOS_VERSION}" "tvos"

# tvOS Simulator - arm64
build_for_platform "tvos-simulator" "arm64" "appletvsimulator" "${MIN_TVOS_VERSION}" "tvos-simulator"

# tvOS Simulator - x86_64
build_for_platform "tvos-simulator" "x86_64" "appletvsimulator" "${MIN_TVOS_VERSION}" "tvos-simulator"

# macOS - arm64 (Apple Silicon)
cd "${FFMPEG_DIR}"
make clean 2>/dev/null || true

./configure \
    --prefix="${OUTPUT_DIR}/macos-arm64" \
    --arch=arm64 \
    --cc="clang -arch arm64" \
    --extra-cflags="-mmacos-version-min=${MIN_MACOS_VERSION}" \
    --extra-ldflags="-mmacos-version-min=${MIN_MACOS_VERSION}" \
    ${COMMON_FLAGS}

make -j$(sysctl -n hw.ncpu)
make install

cd ..

# macOS - x86_64 (Intel)
cd "${FFMPEG_DIR}"
make clean 2>/dev/null || true

./configure \
    --prefix="${OUTPUT_DIR}/macos-x86_64" \
    --arch=x86_64 \
    --cc="clang -arch x86_64" \
    --extra-cflags="-mmacos-version-min=${MIN_MACOS_VERSION}" \
    --extra-ldflags="-mmacos-version-min=${MIN_MACOS_VERSION}" \
    ${COMMON_FLAGS}

make -j$(sysctl -n hw.ncpu)
make install

cd ..

echo "✅ All platforms built!"
