#!/bin/bash
# =========================================================
#  NEX-PACKAGE HANDLER (STRICT PRODUCT MODE)
#  (Forces ALL mods into /product partition only)
# =========================================================

PARTITION_ROOT="$1"
PARTITION_NAME="$2"
TEMP_DIR="$3"
NEX_DIR="nex-package"

# 🔴 STRICT GUARD: EXIT IF NOT PRODUCT
# This ensures we NEVER touch system_ext, system, or vendor.
if [ "$PARTITION_NAME" != "product" ]; then
    echo "      ⚠️  Skipping $PARTITION_NAME (Strict Mode: Product Only)"
    exit 0
fi

echo "      📦 Processing Product Partition..."

# --- HELPER: Find folder dynamically (Scoped to this partition) ---
find_folder() {
    find "$PARTITION_ROOT" -type d -name "$1" -print -quit
}

# 1. INJECT LAUNCHER (MiuiHome)
if [ -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
    # Search for MiuiHome ONLY inside this product dump
    TARGET=$(find "$PARTITION_ROOT" -name "MiuiHome.apk" -type f 2>/dev/null | head -n 1)
    
    if [ ! -z "$TARGET" ]; then
        echo "         - Updating Launcher: $TARGET"
        cp "$TEMP_DIR/MiuiHome_Latest.apk" "$TARGET"
        chmod 644 "$TARGET"
    else
        # If not found, force install into /product/priv-app/MiuiHome/
        echo "         ⚠️  Stock Launcher not found. Force installing to Product..."
        DEST="$PARTITION_ROOT/priv-app/MiuiHome"
        mkdir -p "$DEST"
        cp "$TEMP_DIR/MiuiHome_Latest.apk" "$DEST/MiuiHome.apk"
        chmod 644 "$DEST/MiuiHome.apk"
    fi
fi

# 2. NEX-PACKAGE CONTENT
if [ -d "$NEX_DIR" ]; then
    
    # Locate Media/Overlay folders strictly inside Product
    MEDIA_DIR=$(find_folder "media")
    OVERLAY_DIR=$(find_folder "overlay")
    
    # Fallback: Create them if they don't exist in Product
    if [ -z "$MEDIA_DIR" ]; then
        MEDIA_DIR="$PARTITION_ROOT/media"
        mkdir -p "$MEDIA_DIR"
    fi
    if [ -z "$OVERLAY_DIR" ]; then
        OVERLAY_DIR="$PARTITION_ROOT/overlay"
        mkdir -p "$OVERLAY_DIR"
    fi

    # Bootanimation
    if [ -f "$NEX_DIR/bootanimation.zip" ]; then
        echo "         - Installing Bootanimation to Product..."
        cp "$NEX_DIR/bootanimation.zip" "$MEDIA_DIR/bootanimation.zip"
        chmod 644 "$MEDIA_DIR/bootanimation.zip"
    fi

    # Wallpapers
    if [ -d "$NEX_DIR/walls" ]; then
        echo "         - Installing Wallpapers to Product..."
        mkdir -p "$MEDIA_DIR/wallpaper/wallpaper_group"
        cp -r "$NEX_DIR/walls/"* "$MEDIA_DIR/wallpaper/wallpaper_group/" 2>/dev/null
    fi
    
    # Overlays
    if [ -d "$NEX_DIR/overlays" ]; then
        echo "         - Installing Overlays to Product..."
        cp -r "$NEX_DIR/overlays/"* "$OVERLAY_DIR/"
    fi
fi

# 3. GLOBAL APK MODS (Strictly inside Product)
if [ -d "$NEX_DIR/mods" ]; then
    for MOD_APK in "$NEX_DIR/mods/"*.apk; do
        [ -e "$MOD_APK" ] || continue
        APK_NAME=$(basename "$MOD_APK")
        
        # Skip Launcher (Handled above)
        if [ "$APK_NAME" == "MiuiHome.apk" ] && [ -f "$TEMP_DIR/MiuiHome_Latest.apk" ]; then
            continue
        fi
        
        # Search ONLY inside Product
        FOUND_PATH=$(find "$PARTITION_ROOT" -name "$APK_NAME" -type f 2>/dev/null | head -n 1)
        
        if [ ! -z "$FOUND_PATH" ]; then
            echo "         - Modding Product APK: $APK_NAME"
            cp "$MOD_APK" "$FOUND_PATH"
            chmod 644 "$FOUND_PATH"
        else
            echo "         ⚠️  $APK_NAME not found in Product. Skipping."
        fi
    done
fi
