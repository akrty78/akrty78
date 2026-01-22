#!/bin/bash
# =========================================================
#  NEXDROID DEBLOATER
#  (The "Cleaner" - Removes Bloatware)
# =========================================================

PARTITION_ROOT="$1"
NUKE_LIST_FILE="$2" # Optional: Path to a nuke.txt file

if [ -z "$PARTITION_ROOT" ]; then
    echo "❌ Error: No partition root provided to debloater."
    exit 1
fi

# --- DEFINE BLOATWARE HERE (Folder Names) ---
# Add the exact folder names of apps you want to remove.
BLOAT_APPS=(
    "MSA"
    "Miuidaemon"
    "MiuiDaemon"
    "HybridAccessory"
    "Joyose"
    "SoterService"
    "AnalyticsCore"
    "Facebook"
    "Netflix"
    "MiCoin"
    "MiPay"
    "MiCredit"
    "Updater"
    "MiBrowser"
)

# --- EXECUTION ---
echo "      🗑️  Scanning for Bloatware..."

# Method 1: Hardcoded List (Above)
for app in "${BLOAT_APPS[@]}"; do
    # Find directory matching app name (Case Insensitive)
    found=$(find "$PARTITION_ROOT" -type d -iname "$app" -print -quit)
    
    if [ ! -z "$found" ]; then
        rm -rf "$found"
        echo "         🔥 Nuked: $app"
    fi
done

# Method 2: External nuke.txt (If it exists)
if [ -f "$NUKE_LIST_FILE" ]; then
    echo "      📄 Reading nuke.txt..."
    while IFS= read -r app || [[ -n "$app" ]]; do
        [[ -z "$app" ]] && continue
        found=$(find "$PARTITION_ROOT" -type d -iname "$app" -print -quit)
        if [ ! -z "$found" ]; then
            rm -rf "$found"
            echo "         🔥 Nuked (List): $app"
        fi
    done < "$NUKE_LIST_FILE"
fi
