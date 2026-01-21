#!/bin/bash
# =========================================================
#  NEX-PACKAGE HANDLER
#  (Injects Bootanim, Walls, Overlays, and Modded APKs)
# =========================================================

PARTITION_ROOT="$1"
PARTITION_NAME="$2"
TEMP_DIR="$3"
NEX_DIR="nex-package"

# --- PART 1: PRODUCT PARTITION MODS ---
if [ "$PARTITION_NAME" == "product" ]; then
    echo "      📦 Processing Product Mods..."
    
    # 1. Inject Downloaded MiuiHome (From GitHub Auto-Update)
    if [ -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
        # Find existing MiuiHome to replace it accurately
        TARGET=$(find "$PARTITION_ROOT" -name "MiuiHome.apk" -type f 2>/dev/null | head -n 1)
        
        if [ ! -z "$TARGET" ]; then
            echo "         - Updating Launcher (GitHub Release)..."
            cp "$TEMP_DIR/MiuiHome_Latest.apk" "$TARGET"
            chmod 644 "$TARGET"
        else
            echo "         ⚠️  Stock MiuiHome not found. Skipping update."
        fi
    fi

    # 2. Nex-Package (Media/Overlay)
    if [ -d "$NEX_DIR" ]; then
        # Bootanimation
        MEDIA_DIR=""
        [ -d "$PARTITION_ROOT/media" ] && MEDIA_DIR="$PARTITION_ROOT/media"
        [ -d "$PARTITION_ROOT/product/media" ] && MEDIA_DIR="$PARTITION_ROOT/product/media"
        
        if [ -f "$NEX_DIR/bootanimation.zip" ] && [ ! -z "$MEDIA_DIR" ]; then
            echo "         - Replacing Bootanimation..."
            cp "$NEX_DIR/bootanimation.zip" "$MEDIA_DIR/bootanimation.zip"
            chmod 644 "$MEDIA_DIR/bootanimation.zip"
        fi

        # Wallpapers
        if [ -d "$NEX_DIR/walls" ] && [ ! -z "$MEDIA_DIR" ]; then
            echo "         - Adding Wallpapers..."
            mkdir -p "$MEDIA_DIR/wallpaper/wallpaper_group"
            cp -r "$NEX_DIR/walls/"* "$MEDIA_DIR/wallpaper/wallpaper_group/" 2>/dev/null
        fi
        
        # Overlays
        OVERLAY_DIR=""
        [ -d "$PARTITION_ROOT/overlay" ] && OVERLAY_DIR="$PARTITION_ROOT/overlay"
        [ -d "$PARTITION_ROOT/product/overlay" ] && OVERLAY_DIR="$PARTITION_ROOT/product/overlay"
        
        if [ -d "$NEX_DIR/overlays" ] && [ ! -z "$OVERLAY_DIR" ]; then
            echo "         - Injecting Overlays..."
            cp -r "$NEX_DIR/overlays/"* "$OVERLAY_DIR/"
        fi
    fi
fi

# --- PART 2: GLOBAL APK MODS (Any Partition) ---
if [ -d "$NEX_DIR/mods" ]; then
    for MOD_APK in "$NEX_DIR/mods/"*.apk; do
        [ -e "$MOD_APK" ] || continue
        APK_NAME=$(basename "$MOD_APK")
        
        # SKIP MiuiHome here (handled above via GitHub update)
        if [ "$APK_NAME" == "MiuiHome.apk" ] && [ -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
            continue
        fi
        
        # Smart Replace: Find where the APK lives and overwrite it
        FOUND_PATH=$(find "$PARTITION_ROOT" -name "$APK_NAME" -type f 2>/dev/null | head -n 1)
        if [ ! -z "$FOUND_PATH" ]; then
            echo "         - Modding: $APK_NAME"
            cp "$MOD_APK" "$FOUND_PATH"
            chmod 644 "$FOUND_PATH"
        fi
    done
fi
