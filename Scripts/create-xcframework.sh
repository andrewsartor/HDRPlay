#!/bin/bash
set -e

# Configuration
FRAMEWORKS_DIR="$(pwd)/Frameworks"
OUTPUT_DIR="${FRAMEWORKS_DIR}/xcframework"

# Clean up previous builds
rm -rf "${OUTPUT_DIR}"/*xcframework

mkdir -p "${OUTPUT_DIR}"

echo "🚀 Creating individual FFmpeg XCFrameworks..."

# FFmpeg libraries to create individual XCFrameworks for
LIBS=("libavformat" "libavcodec" "libavutil" "libswresample" "libswscale")

# Detect library type (static .a or dynamic .dylib)
detect_lib_type() {
    local platform_dir=$1
    if [[ -f "${platform_dir}/lib/libavutil.a" ]]; then
        echo "a"
    elif [[ -f "${platform_dir}/lib/libavutil.dylib" ]]; then
        echo "dylib"
    else
        echo "❌ Error: No libavutil found in ${platform_dir}/lib/"
        exit 1
    fi
}

# Function to extract library-specific headers
extract_library_headers() {
    local platform_path=$1
    local lib_name=$2
    local temp_headers_dir="${platform_path}/include_${lib_name}"
    
    # Remove temp directory if it exists
    rm -rf "${temp_headers_dir}"
    mkdir -p "${temp_headers_dir}"
    
    # Extract the library-specific subdirectory name (e.g., "libavcodec" -> "libavcodec")
    local header_subdir="${lib_name}"
    
    # Copy only the specific library's headers
    if [[ -d "${platform_path}/include/${header_subdir}" ]]; then
        cp -R "${platform_path}/include/${header_subdir}" "${temp_headers_dir}/"
        echo "${temp_headers_dir}"
        return 0
    else
        echo "  ⚠️  Warning: No headers found at ${platform_path}/include/${header_subdir}"
        return 1
    fi
}

# Function to create XCFramework for a single library
create_library_xcframework() {
    local lib_name=$1
    local lib_type=$2
    
    echo "📦 Creating XCFramework for ${lib_name}..."
    
    local xcframework_args=()
    local platforms_found=0
    
    # Check all possible platform combinations
    local platform_configs=(
        "ios-arm64:${FRAMEWORKS_DIR}/ios-arm64"
        "ios-simulator:${FRAMEWORKS_DIR}/ios-simulator"
        "tvos-arm64:${FRAMEWORKS_DIR}/tvos-arm64" 
        "tvos-simulator:${FRAMEWORKS_DIR}/tvos-simulator"
        "macos:${FRAMEWORKS_DIR}/macos"
    )
    
    # First, create universal binaries for simulators if needed
    if [[ -d "${FRAMEWORKS_DIR}/ios-simulator-arm64" ]] && [[ -d "${FRAMEWORKS_DIR}/ios-simulator-x86_64" ]]; then
        mkdir -p "${FRAMEWORKS_DIR}/ios-simulator/lib"
        local lib1="${FRAMEWORKS_DIR}/ios-simulator-arm64/lib/${lib_name}.${lib_type}"
        local lib2="${FRAMEWORKS_DIR}/ios-simulator-x86_64/lib/${lib_name}.${lib_type}"
        local output="${FRAMEWORKS_DIR}/ios-simulator/lib/${lib_name}.${lib_type}"
        
        if [[ -f "${lib1}" ]] && [[ -f "${lib2}" ]]; then
            if ! lipo -create "${lib1}" "${lib2}" -output "${output}"; then
                echo "  ⚠️  Failed to create iOS simulator universal binary, using arm64 only"
                cp "${lib1}" "${output}" 2>/dev/null || true
            fi
        elif [[ -f "${lib1}" ]]; then
            cp "${lib1}" "${output}"
        elif [[ -f "${lib2}" ]]; then
            cp "${lib2}" "${output}"
        fi
        
        # Copy headers if not already present
        if [[ ! -d "${FRAMEWORKS_DIR}/ios-simulator/include" ]] && [[ -d "${FRAMEWORKS_DIR}/ios-simulator-arm64/include" ]]; then
            cp -R "${FRAMEWORKS_DIR}/ios-simulator-arm64/include" "${FRAMEWORKS_DIR}/ios-simulator/"
        fi
    fi
    
    # Do the same for tvOS simulator
    if [[ -d "${FRAMEWORKS_DIR}/tvos-simulator-arm64" ]] && [[ -d "${FRAMEWORKS_DIR}/tvos-simulator-x86_64" ]]; then
        mkdir -p "${FRAMEWORKS_DIR}/tvos-simulator/lib"
        local lib1="${FRAMEWORKS_DIR}/tvos-simulator-arm64/lib/${lib_name}.${lib_type}"
        local lib2="${FRAMEWORKS_DIR}/tvos-simulator-x86_64/lib/${lib_name}.${lib_type}"
        local output="${FRAMEWORKS_DIR}/tvos-simulator/lib/${lib_name}.${lib_type}"
        
        if [[ -f "${lib1}" ]] && [[ -f "${lib2}" ]]; then
            if ! lipo -create "${lib1}" "${lib2}" -output "${output}"; then
                echo "  ⚠️  Failed to create tvOS simulator universal binary, using arm64 only"
                cp "${lib1}" "${output}" 2>/dev/null || true
            fi
        elif [[ -f "${lib1}" ]]; then
            cp "${lib1}" "${output}"
        elif [[ -f "${lib2}" ]]; then
            cp "${lib2}" "${output}"
        fi
        
        if [[ ! -d "${FRAMEWORKS_DIR}/tvos-simulator/include" ]] && [[ -d "${FRAMEWORKS_DIR}/tvos-simulator-arm64/include" ]]; then
            cp -R "${FRAMEWORKS_DIR}/tvos-simulator-arm64/include" "${FRAMEWORKS_DIR}/tvos-simulator/"
        fi
    fi
    
    # Do the same for macOS
    if [[ -d "${FRAMEWORKS_DIR}/macos-arm64" ]] && [[ -d "${FRAMEWORKS_DIR}/macos-x86_64" ]]; then
        mkdir -p "${FRAMEWORKS_DIR}/macos/lib"
        local lib1="${FRAMEWORKS_DIR}/macos-arm64/lib/${lib_name}.${lib_type}"
        local lib2="${FRAMEWORKS_DIR}/macos-x86_64/lib/${lib_name}.${lib_type}"
        local output="${FRAMEWORKS_DIR}/macos/lib/${lib_name}.${lib_type}"
        
        if [[ -f "${lib1}" ]] && [[ -f "${lib2}" ]]; then
            if ! lipo -create "${lib1}" "${lib2}" -output "${output}"; then
                echo "  ⚠️  Failed to create macOS universal binary, using arm64 only"
                cp "${lib1}" "${output}" 2>/dev/null || true
            fi
        elif [[ -f "${lib1}" ]]; then
            cp "${lib1}" "${output}"
        elif [[ -f "${lib2}" ]]; then
            cp "${lib2}" "${output}"
        fi
        
        if [[ ! -d "${FRAMEWORKS_DIR}/macos/include" ]] && [[ -d "${FRAMEWORKS_DIR}/macos-arm64/include" ]]; then
            cp -R "${FRAMEWORKS_DIR}/macos-arm64/include" "${FRAMEWORKS_DIR}/macos/"
        fi
    fi
    
    # Now build XCFramework arguments for each platform
    for config in "${platform_configs[@]}"; do
        local platform_name="${config%%:*}"
        local platform_path="${config##*:}"

        local lib_file="${platform_path}/lib/${lib_name}.${lib_type}"

        # Resolve symlinks to actual binary file
        if [[ -L "${lib_file}" ]]; then
            lib_file=$(readlink -f "${lib_file}" 2>/dev/null || realpath "${lib_file}" 2>/dev/null || echo "${lib_file}")
        fi

        if [[ -f "${lib_file}" ]]; then
            # Fix install_name to use @rpath for dynamic libraries
            if [[ "${lib_type}" == "dylib" ]]; then
                # Get the full filename for the install_name (e.g., libavformat.62.3.100.dylib)
                local lib_basename=$(basename "${lib_file}")
                local install_name="@rpath/${lib_basename}"

                # Change the install_name
                install_name_tool -id "${install_name}" "${lib_file}" 2>/dev/null || true

                # Fix dependencies on other FFmpeg libraries to use @rpath with full version names
                for dep_lib in "${LIBS[@]}"; do
                    # Find any dependency path (even if already using @rpath)
                    local old_dep=$(otool -L "${lib_file}" | grep "${dep_lib}" | awk '{print $1}' | head -1)
                    if [[ -n "${old_dep}" ]] && [[ "${old_dep}" != "${lib_file}:"* ]]; then
                        # Find the actual dependency file in the same lib directory
                        local dep_dir=$(dirname "${lib_file}")
                        local dep_file=$(find "${dep_dir}" -name "${dep_lib}.*.*.*.dylib" | head -1)
                        if [[ -n "${dep_file}" ]]; then
                            local dep_basename=$(basename "${dep_file}")
                            local new_dep="@rpath/${dep_basename}"
                            # Only change if it's different
                            if [[ "${old_dep}" != "${new_dep}" ]]; then
                                install_name_tool -change "${old_dep}" "${new_dep}" "${lib_file}" 2>/dev/null || true
                                echo "      Updated dependency: ${dep_lib} -> ${dep_basename}"
                            fi
                        fi
                    fi
                done

                # Create symlink for major version (e.g., libavformat.62.dylib -> libavformat.62.3.100.dylib)
                local lib_dir=$(dirname "${lib_file}")
                local lib_basename=$(basename "${lib_file}")
                if [[ "${lib_basename}" =~ ^(.+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\.dylib$ ]]; then
                    local base_name="${BASH_REMATCH[1]}"
                    local major="${BASH_REMATCH[2]}"
                    local symlink_name="${base_name}.${major}.dylib"
                    (cd "${lib_dir}" && ln -sf "${lib_basename}" "${symlink_name}")
                    echo "  🔗 Created symlink: ${symlink_name} -> ${lib_basename}"
                fi
            fi

            # Extract library-specific headers
            local headers_path=$(extract_library_headers "${platform_path}" "${lib_name}")
            
            if [[ -n "${headers_path}" ]] && [[ -d "${headers_path}" ]]; then
                # Check if library has substantial content (follow symlinks with -L)
                local lib_size=$(stat -L -f%z "${lib_file}" 2>/dev/null || stat -L -c%s "${lib_file}" 2>/dev/null || echo "0")
                if [[ "${lib_size}" -gt "100" ]]; then
                    xcframework_args+=("-library" "${lib_file}")
                    xcframework_args+=("-headers" "${headers_path}")
                    platforms_found=$((platforms_found + 1))
                    echo "  ✅ Added ${platform_name} (${lib_size} bytes)"
                else
                    echo "  ⚠️  Skipping ${platform_name} - library too small (${lib_size} bytes)"
                fi
            else
                echo "  ⚠️  Skipping ${platform_name} - headers extraction failed"
            fi
        else
            echo "  ⚠️  Skipping ${platform_name} - library missing"
        fi
    done
    
    if [[ ${platforms_found} -eq 0 ]]; then
        echo "  ❌ No valid platforms found for ${lib_name}"
        return 1
    fi
    
    # Create the XCFramework
    local output_xcframework="${OUTPUT_DIR}/${lib_name}.xcframework"
    if xcodebuild -create-xcframework "${xcframework_args[@]}" -output "${output_xcframework}"; then
        echo "  ✅ Created ${lib_name}.xcframework with ${platforms_found} platform(s)"
        
        # Clean up temporary header directories
        for config in "${platform_configs[@]}"; do
            local platform_path="${config##*:}"
            rm -rf "${platform_path}/include_${lib_name}"
        done
        
        return 0
    else
        echo "  ❌ Failed to create ${lib_name}.xcframework"
        return 1
    fi
}

# Detect library type from the first available platform
LIB_TYPE=""
for platform_dir in "${FRAMEWORKS_DIR}"/*/; do
    if [[ -d "$platform_dir" ]] && [[ "$(basename "$platform_dir")" != "xcframework" ]] && [[ "$(basename "$platform_dir")" != "temp" ]]; then
        LIB_TYPE=$(detect_lib_type "$platform_dir")
        break
    fi
done

if [[ -z "${LIB_TYPE}" ]]; then
    echo "❌ Error: No platform directories found"
    exit 1
fi

echo "📋 Detected library type: ${LIB_TYPE}"

# Create XCFramework for each library
CREATED_FRAMEWORKS=0
for lib in "${LIBS[@]}"; do
    if create_library_xcframework "${lib}" "${LIB_TYPE}"; then
        CREATED_FRAMEWORKS=$((CREATED_FRAMEWORKS + 1))
    fi
    echo ""
done

if [[ ${CREATED_FRAMEWORKS} -eq 0 ]]; then
    echo "❌ Error: No XCFrameworks were created successfully"
    exit 1
fi

echo "🎉 Build complete!"
echo "✅ Created ${CREATED_FRAMEWORKS} XCFramework(s) in ${OUTPUT_DIR}/"
echo ""
echo "📝 Next steps:"
echo "1. Update your Package.swift to use individual binary targets:"
echo "   .binaryTarget(name: \"libavformat\", path: \"Frameworks/xcframework/libavformat.xcframework\")"
echo "   .binaryTarget(name: \"libavcodec\", path: \"Frameworks/xcframework/libavcodec.xcframework\")"
echo "   ... etc for each library"
echo ""
echo "2. Your CFFmpeg target dependencies should list all the individual libraries"
