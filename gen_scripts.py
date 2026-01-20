import os
import sys
import platform

# Usage: python3 gen_scripts.py <device_code> <path_to_images_dir>
if len(sys.argv) < 3:
    print("Usage: gen_scripts.py <device> <img_dir>")
    sys.exit(1)

DEVICE = sys.argv[1]
IMG_DIR = sys.argv[2]

# Detect actual images present to avoid flashing missing files
files = os.listdir(IMG_DIR)
images = [f for f in files if f.endswith(".img")]

# Priority List (Flash these first)
BOOT_IMGS = ["boot.img", "vendor_boot.img", "dtbo.img", "recovery.img"]
VBMETA_IMGS = ["vbmeta.img", "vbmeta_system.img", "vbmeta_vendor.img"]
SUPER_IMG = "super.img"

# --- TEMPLATES ---
HEADER_BAT = f"""@echo off
title NexDroid Gooner Installer - {DEVICE}
color 0b
echo ==============================================
echo      NEXDROID GOONER - {DEVICE}
echo ==============================================
echo.
fastboot devices
echo.
"""

HEADER_SH = f"""#!/bin/bash
echo "=============================================="
echo "     NEXDROID GOONER - {DEVICE}"
echo "=============================================="
echo ""
fastboot devices
echo ""
"""

# --- GENERATOR FUNCTIONS ---

def get_flash_cmds(os_type="win", wipe=False):
    cmds = []
    
    # 1. Anti-Lock & FRP (Safety)
    if os_type == "win":
        cmds.append("fastboot erase frp")
        cmds.append("fastboot erase misc")
    else:
        cmds.append("fastboot erase frp")
        cmds.append("fastboot erase misc")

    # 2. Flash Firmware (Boot, Vbmeta, etc)
    # We sort them: Boot first, then Vbmeta, then others
    for img in BOOT_IMGS:
        if img in images: cmds.append(f"fastboot flash {img.split('.')[0]} images/{img}")
    
    for img in VBMETA_IMGS:
        if img in images: 
            # Disable verification flags for vbmeta
            cmds.append(f"fastboot --disable-verity --disable-verification flash {img.split('.')[0]} images/{img}")

    # Flash other miscellaneous images (modem, dsp, etc)
    for img in images:
        if img not in BOOT_IMGS and img not in VBMETA_IMGS and img != SUPER_IMG:
            part = img.split('.')[0]
            cmds.append(f"fastboot flash {part} images/{img}")

    # 3. Flash Super (The Big One)
    if SUPER_IMG in images:
        cmds.append(f"fastboot flash super images/{SUPER_IMG}")

    # 4. Wipe Data (If Clean Flash)
    if wipe:
        cmds.append("fastboot -w")
    
    # 5. Reboot
    cmds.append("fastboot reboot")
    
    # Pause for Windows so user sees output
    if os_type == "win":
        cmds.append("pause")
        
    return cmds

# --- WRITE FILES ---

# 1. Windows Clean
with open("flash_clean.bat", "w") as f:
    f.write(HEADER_BAT)
    f.write("echo [!] THIS WILL WIPE ALL DATA. PRESS CTRL+C TO CANCEL.\n")
    f.write("pause\n")
    f.write("\n".join(get_flash_cmds("win", wipe=True)))

# 2. Windows Dirty
with open("flash_dirty.bat", "w") as f:
    f.write(HEADER_BAT)
    f.write("echo [*] Dirty Flash Mode (Data Kept).\n")
    f.write("\n".join(get_flash_cmds("win", wipe=False)))

# 3. Linux/Mac Clean
with open("flash_clean.sh", "w") as f:
    f.write(HEADER_SH)
    f.write("read -p '[!] THIS WILL WIPE ALL DATA. Press Enter to continue...' \n")
    f.write("\n".join(get_flash_cmds("linux", wipe=True)))

# 4. Linux/Mac Dirty
with open("flash_dirty.sh", "w") as f:
    f.write(HEADER_SH)
    f.write("echo '[*] Dirty Flash Mode (Data Kept).'\n")
    f.write("\n".join(get_flash_cmds("linux", wipe=False)))

print("✅ Scripts Generated Successfully.")
