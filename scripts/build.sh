#!/usr/bin/env bash
set -euo pipefail

# Pretty Logging
ARROW="\033[1;34m==>\033[0m"
TICK="\033[0;32m✓\033[0m"

log_info() { :; }
log_success() { :; }
log_warn() { :; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

log_header() { echo -e "${ARROW} $*..."; }
log_step_success() { echo -e "${TICK} $*"; }

run_cmd() {
    local log_file
    log_file=$(mktemp)
    if ! "$@" > "$log_file" 2>&1; then
        echo -e "\n\033[0;31m[ERROR] Command failed: $*\033[0m"
        echo "----------------------------------------"
        cat "$log_file"
        echo "----------------------------------------"
        rm -f "$log_file"
        exit 1
    fi
    rm -f "$log_file"
}

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORKSPACE_DIR="workspace"
EXTRACT_DIR="$WORKSPACE_DIR/extracted"
SYS_DIR="$WORKSPACE_DIR/sys_dir"
INPUT_IMAGE="$WORKSPACE_DIR/system.img"
OUTPUT_IMAGE="$WORKSPACE_DIR/system_new.img"

log_info "Initializing GSI Builder..."

# Validate GSI URL
if [ -z "${GSI_URL:-}" ]; then
    log_error "GSI_URL environment variable is required."
    exit 1
fi

OUTPUT_FS="${OUTPUT_FS:-ext4}"
COMPRESS_OUTPUT="${COMPRESS_OUTPUT:-none}"

# Ensure we run as root (or with sudo privileges) since loop mounting is required
if [ "$EUID" -ne 0 ]; then
    log_warn "This script requires superuser privileges to mount images. Re-running with sudo..."
    exec sudo GSI_URL="$GSI_URL" \
         OUTPUT_FS="$OUTPUT_FS" \
         REMOVE_VNDK_V28="${REMOVE_VNDK_V28:-false}" \
         REMOVE_VNDK_V29="${REMOVE_VNDK_V29:-false}" \
         REMOVE_VNDK_V30="${REMOVE_VNDK_V30:-false}" \
         REMOVE_VNDK_V31="${REMOVE_VNDK_V31:-false}" \
         REMOVE_VNDK_V32="${REMOVE_VNDK_V32:-false}" \
         REMOVE_VNDK_V33="${REMOVE_VNDK_V33:-false}" \
         REMOVE_WALLPAPERS="${REMOVE_WALLPAPERS:-false}" \
         REMOVE_SOUNDS="${REMOVE_SOUNDS:-false}" \
         REMOVE_FONTS="${REMOVE_FONTS:-false}" \
         REMOVE_LIVE_WALLPAPERS="${REMOVE_LIVE_WALLPAPERS:-false}" \
         REMOVE_PIXEL_THEMES="${REMOVE_PIXEL_THEMES:-false}" \
         COMPRESS_OUTPUT="$COMPRESS_OUTPUT" \
         bash "$0" "$@"
fi

# Create workspace directories
mkdir -p "$WORKSPACE_DIR"
rm -rf "$SYS_DIR"
mkdir -p "$SYS_DIR"

log_info "Calculating GSI naming..."
# Check if any VNDKs were removed
REMOVE_VNDK="false"
for ver in 28 29 30 31 32 33; do
    var_name="REMOVE_VNDK_V${ver}"
    if [ "${!var_name:-false}" = "true" ]; then
        REMOVE_VNDK="true"
        break
    fi
done

# Check if any debloating was requested
DEBLOAT="false"
DEBLOAT_VARS=(
    "REMOVE_WALLPAPERS"
    "REMOVE_SOUNDS"
    "REMOVE_FONTS"
    "REMOVE_LIVE_WALLPAPERS"
    "REMOVE_PIXEL_THEMES"
)
for var in "${DEBLOAT_VARS[@]}"; do
    if [ "${!var:-false}" = "true" ]; then
        DEBLOAT="true"
        break
    fi
done

# Extract original filename from URL (stripping query parameters)
ORIG_FILENAME=$(basename "$GSI_URL")
ORIG_FILENAME="${ORIG_FILENAME%%\?*}"

# Strip known compression/archive and image extensions to find the core base name
TEMP_NAME="$ORIG_FILENAME"
while true; do
    case "$TEMP_NAME" in
        *.xz) TEMP_NAME="${TEMP_NAME%.xz}" ;;
        *.7z) TEMP_NAME="${TEMP_NAME%.7z}" ;;
        *.zip) TEMP_NAME="${TEMP_NAME%.zip}" ;;
        *.gz) TEMP_NAME="${TEMP_NAME%.gz}" ;;
        *.tar) TEMP_NAME="${TEMP_NAME%.tar}" ;;
        *.tgz) TEMP_NAME="${TEMP_NAME%.tgz}" ;;
        *.img) TEMP_NAME="${TEMP_NAME%.img}" ;;
        *) break ;;
    esac
done
BASE_GSI_NAME="$TEMP_NAME"

# Detect and extract date suffix at the end (e.g. -20260711, _20260711, -2026-07-11)
DATE_SUFFIX=""
if [[ "$BASE_GSI_NAME" =~ ([-_][0-9]{8}|[-_][0-9]{4}[-_][0-9]{2}[-_][0-9]{2})$ ]]; then
    DATE_SUFFIX="${BASH_REMATCH[1]}"
    BASE_GSI_NAME="${BASE_GSI_NAME%"$DATE_SUFFIX"}"
fi

# Strip trailing tags like EROFS, EXT4, DEBLOATED, VNDK (case-insensitive)
shopt -s nocasematch
while true; do
    if [[ "$BASE_GSI_NAME" =~ ([-_]erofs|[-_]ext4|[-_]debloated|[-_]vndk)$ ]]; then
        SUFFIX="${BASH_REMATCH[1]}"
        BASE_GSI_NAME="${BASE_GSI_NAME%"$SUFFIX"}"
    else
        break
    fi
done
shopt -u nocasematch

# Build tags
TAGS=""
if [ "$REMOVE_VNDK" = "true" ]; then
    TAGS="${TAGS}-VNDK"
fi
if [ "$DEBLOAT" = "true" ]; then
    TAGS="${TAGS}-DEBLOATED"
fi

# Upper case target filesystem tag
FS_TYPE=$(echo "$OUTPUT_FS" | tr '[:lower:]' '[:upper:]')
TAGS="${TAGS}-${FS_TYPE}"

# Re-assemble the new raw image name
OUT_IMG_NAME="${BASE_GSI_NAME}${TAGS}${DATE_SUFFIX}.img"

# Compression extension
COMPRESS_EXT=""
if [ "$COMPRESS_OUTPUT" = "xz" ]; then
    COMPRESS_EXT=".xz"
elif [ "$COMPRESS_OUTPUT" = "7z" ]; then
    COMPRESS_EXT=".7z"
fi

OUT_FILE_NAME="${OUT_IMG_NAME}${COMPRESS_EXT}"
OUT_FILE="$WORKSPACE_DIR/$OUT_FILE_NAME"
CHECKSUM_FILE="${OUT_FILE}.sha256"

log_info "Original Filename: $ORIG_FILENAME"
log_info "Target Image Filename: $OUT_IMG_NAME"
log_info "Output Filename: $OUT_FILE_NAME"

# Download setup
DOWNLOADED_FILE="$WORKSPACE_DIR/gsi_archive"
if [[ "$GSI_URL" =~ \.xz$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.xz"
elif [[ "$GSI_URL" =~ \.7z$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.7z"
elif [[ "$GSI_URL" =~ \.zip$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.zip"
elif [[ "$GSI_URL" =~ \.tar\.gz$ || "$GSI_URL" =~ \.tgz$ ]]; then
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.tar.gz"
else
    DOWNLOADED_FILE="${DOWNLOADED_FILE}.img"
fi

# 1. Download GSI
log_header "Download GSI"
run_cmd bash "$SCRIPT_DIR/download.sh" "$GSI_URL" "$DOWNLOADED_FILE"
DOWNLOAD_SIZE=$(du -sh "$DOWNLOADED_FILE" | cut -f1)
log_step_success "Download complete ($DOWNLOAD_SIZE)"

# 2. Extract GSI
log_header "Extract GSI"
run_cmd bash "$SCRIPT_DIR/extract.sh" "$DOWNLOADED_FILE" "$EXTRACT_DIR" "$INPUT_IMAGE"
log_step_success "Extraction complete"

# Detect Filesystem of original RAW image
log_header "Detect filesystem type"
detect_fs_type() {
    local img="$1"
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$img" 2>/dev/null || true)
    if [ -z "$fs_type" ]; then
        local file_info
        file_info=$(file -b "$img")
        if echo "$file_info" | grep -qi "erofs"; then
            fs_type="erofs"
        elif echo "$file_info" | grep -qi "ext4"; then
            fs_type="ext4"
        fi
    fi
    echo "$fs_type"
}

ORIGINAL_FS=$(detect_fs_type "$INPUT_IMAGE")
if [ -z "$ORIGINAL_FS" ]; then
    log_error "Could not detect filesystem of GSI image $INPUT_IMAGE (must be ext4 or erofs)."
    exit 1
fi
FS_UPPER=$(echo "$ORIGINAL_FS" | tr '[:lower:]' '[:upper:]')
log_step_success "$FS_UPPER detected"

# 3. Mount GSI partition and copy contents
log_header "Mount GSI partition"
MNT_SRC=$(mktemp -d -p "$PWD" mnt_src.XXXXXX)
if ! mount -o loop,ro "$INPUT_IMAGE" "$MNT_SRC" >/dev/null 2>&1; then
    log_error "Failed to mount GSI image read-only."
    rm -rf "$MNT_SRC"
    exit 1
fi
cp -a "$MNT_SRC/." "$SYS_DIR/"
umount "$MNT_SRC"
rm -rf "$MNT_SRC"
log_step_success "Mount and copy complete"

# 4. Remove selected VNDKs
if [ "$REMOVE_VNDK" = "true" ]; then
    log_header "Remove selected VNDKs"
    run_cmd bash "$SCRIPT_DIR/remove_vndk.sh" "$SYS_DIR"
    echo -e "${TICK} Removed:"
    for ver in 28 29 30 31 32 33; do
        var_name="REMOVE_VNDK_V${ver}"
        if [ "${!var_name:-false}" = "true" ]; then
            echo "  - v$ver"
        fi
    done
fi
# --- SUNTIKAN SETINGAN TREBLE REDMI 10 (SELENE) ---
echo "persist.sys.phh.hardware_media=true" >> system/build.prop
echo "persist.sys.phh.biometrics_strong=true" >> system/build.prop
echo "persist.sys.phh.securize=true" >> system/build.prop
echo "persist.sys.phh.expose_aux_camera=true" >> system/build.prop
echo "persist.sys.phh.camera.hal3=true" >> system/build.prop
echo "persist.sys.phh.disable_fast_audio=true" >> system/build.prop
echo "persist.sys.phh.disable_voice_call_in=true" >> system/build.prop
echo "persist.sys.phh.system_wide_bt_hal=true" >> system/build.prop
echo "debug.sf.disable_gl_backpressure=1" >> system/build.prop
echo "debug.sf.disable_hwc_backpressure=1" >> system/build.prop
echo "debug.sf.latch_unsignaled=1" >> system/build.prop
echo "debug.sf.auto_latch_unsignaled=1" >> system/build.prop
echo "debug.sf.disable_backpressure=1" >> system/build.prop
echo "debug.sf.disable_hwc=1" >> system/build.prop
echo "persist.sys.phh.aod=true" >> system/build.prop
echo "persist.sys.phh.xiaomi.dt2w=true" >> system/build.prop
echo "persist.sys.phh.mtk_touch_rotation=true" >> system/build.prop
echo "persist.sys.phh.mtk_ged_kpi=true" >> system/build.prop
echo "persist.sys.phh.mtk_force_cognitive=true" >> system/build.prop
fi
# --- MENGHAPUS / HIDE TREBLE APP ---
# Ini akan membuat HP kamu terlihat seperti custom ROM murni tanpa embel-embel GSI
rm -rf system/app/TrebleApp
rm -rf system/app/PhhTrebleApp
rm -rf system/priv-app/TrebleApp
rm -rf system/priv-app/PhhTrebleApp
fi
# 5. Apply debloating
if [ "$DEBLOAT" = "true" ]; then
    log_header "Debloat system partition"
    run_cmd bash "$SCRIPT_DIR/debloat.sh" "$SYS_DIR"
    echo -e "${TICK} Removed:"
    if [ "${REMOVE_WALLPAPERS:-false}" = "true" ]; then echo "  - Static Wallpapers"; fi
    if [ "${REMOVE_SOUNDS:-false}" = "true" ]; then echo "  - System Sounds"; fi
    if [ "${REMOVE_FONTS:-false}" = "true" ]; then echo "  - Non-essential Fonts"; fi
    if [ "${REMOVE_LIVE_WALLPAPERS:-false}" = "true" ]; then echo "  - Live Wallpapers"; fi
    if [ "${REMOVE_PIXEL_THEMES:-false}" = "true" ]; then echo "  - Pixel Theme Overlays"; fi
fi

# 6. Build GSI image
log_header "Build GSI image (${FS_TYPE})"
case "$OUTPUT_FS" in
    ext4)
        run_cmd bash "$SCRIPT_DIR/build_ext4.sh" "$SYS_DIR" "$OUTPUT_IMAGE"
        ;;
    erofs)
        run_cmd bash "$SCRIPT_DIR/build_erofs.sh" "$SYS_DIR" "$OUTPUT_IMAGE"
        ;;
    *)
        log_error "Unsupported output filesystem: $OUTPUT_FS"
        exit 1
        ;;
esac
log_step_success "Build complete"

# 7. Compress GSI image
if [ "$COMPRESS_OUTPUT" != "none" ]; then
    COMP_UPPER=$(echo "$COMPRESS_OUTPUT" | tr '[:lower:]' '[:upper:]')
    log_header "Compress GSI image"
    run_cmd bash "$SCRIPT_DIR/compress.sh" "$OUTPUT_IMAGE" "$COMPRESS_OUTPUT" "$OUT_FILE"
    log_step_success "Compression complete"
else
    run_cmd bash "$SCRIPT_DIR/compress.sh" "$OUTPUT_IMAGE" "$COMPRESS_OUTPUT" "$OUT_FILE"
fi

# 8. Generate SHA256 checksum
log_header "Generate SHA256"
run_cmd bash "$SCRIPT_DIR/checksum.sh" "$OUT_FILE" "$CHECKSUM_FILE"
log_step_success "Done"

# 9. Clean up intermediate workspace files
rm -f "$DOWNLOADED_FILE"
rm -f "$INPUT_IMAGE"
rm -f "$OUTPUT_IMAGE"
rm -rf "$EXTRACT_DIR"
rm -rf "$SYS_DIR"

echo ""
