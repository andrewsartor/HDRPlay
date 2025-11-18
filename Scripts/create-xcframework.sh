#!/bin/bash
set -e

FRAMEWORKS_DIR="$(pwd)/Frameworks"
OUTPUT_DIR="${FRAMEWORKS_DIR}/xcframework"

mkdir -p "${OUTPUT_DIR}"

# Libraries to process
LIBS=("libavformat" "libavcodec" "libavutil" "libswresample" "libswscale")

for LIB in "${LIBS[@]}"; do
    echo "Creating XCFramework for ${LIB}..."
    
    # Create fat binary for iOS Simulator (arm64 + x86_64)
    mkdir -p "${FRAMEWORKS_DIR}/ios-simulator-universal/lib"
    lipo -create \
        "${FRAMEWORKS_DIR}/ios-simulator-arm64/lib/${LIB}.dylib" \
        "${FRAMEWORKS_DIR}/ios-simulator-x86_64/lib/${LIB}.dylib" \
        -output "${FRAMEWORKS_DIR}/ios-simulator-universal/lib/${LIB}.dylib"
    
    # Create fat binary for tvOS Simulator (arm64 + x86_64)
    mkdir -p "${FRAMEWORKS_DIR}/tvos-simulator-universal/lib"
    lipo -create \
        "${FRAMEWORKS_DIR}/tvos-simulator-arm64/lib/${LIB}.dylib" \
        "${FRAMEWORKS_DIR}/tvos-simulator-x86_64/lib/${LIB}.dylib" \
        -output "${FRAMEWORKS_DIR}/tvos-simulator-universal/lib/${LIB}.dylib"
    
    # Create fat binary for macOS (arm64 + x86_64)
    mkdir -p "${FRAMEWORKS_DIR}/macos-universal/lib"
    lipo -create \
        "${FRAMEWORKS_DIR}/macos-arm64/lib/${LIB}.dylib" \
        "${FRAMEWORKS_DIR}/macos-x86_64/lib/${LIB}.dylib" \
        -output "${FRAMEWORKS_DIR}/macos-universal/lib/${LIB}.dylib"
    
    # Create XCFramework
    xcodebuild -create-xcframework \
        -library "${FRAMEWORKS_DIR}/ios-arm64/lib/${LIB}.dylib" \
        -headers "${FRAMEWORKS_DIR}/ios-arm64/include" \
        -library "${FRAMEWORKS_DIR}/ios-simulator-universal/lib/${LIB}.dylib" \
        -headers "${FRAMEWORKS_DIR}/ios-simulator-arm64/include" \
        -library "${FRAMEWORKS_DIR}/tvos-arm64/lib/${LIB}.dylib" \
        -headers "${FRAMEWORKS_DIR}/tvos-arm64/include" \
        -library "${FRAMEWORKS_DIR}/tvos-simulator-universal/lib/${LIB}.dylib" \
        -headers "${FRAMEWORKS_DIR}/tvos-simulator-arm64/include" \
        -library "${FRAMEWORKS_DIR}/macos-universal/lib/${LIB}.dylib" \
        -headers "${FRAMEWORKS_DIR}/macos-arm64/include" \
        -output "${OUTPUT_DIR}/${LIB}.xcframework"
    
    echo "✅ Created ${LIB}.xcframework"
done

echo "✅ All XCFrameworks created in ${OUTPUT_DIR}"
