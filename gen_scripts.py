import os
import sys

if len(sys.argv) < 3:
    print("Usage: gen_scripts.py <device_code> <path_to_images_dir>")
    sys.exit(1)

DEVICE = sys.argv[1]
IMG_DIR = sys.argv[2]

# Detect actual images present
files = os.listdir(IMG_DIR)
images = [f for f in files if f.endswith(".img")]

# Flashing Order
BOOT_IMGS = ["boot.img", "vendor_boot.img", "dtbo.img", "recovery.img", "init_boot.img"]
VBMETA_IMGS = ["vbmeta.img", "vbmeta_system.img", "vbmeta_vendor.img"]
SUPER_IMG = "super.img"

HEADER_BAT = f"@echo off\ntitle NexDroid Gooner Installer - {DEVICE}\ncolor 0b\necho NEXDROID GOONER - {DEVICE}\necho.\nfastboot devices\necho.\n"
HEADER_SH = f"#!/bin/bash\necho 'NEXDROID GOONER - {DEVICE}'\nfastboot devices\n"

def get_cmds(os_type, wipe):
    cmds = []
    # 1. Safety & FRP
    cmds.append("fastboot erase frp")
    cmds.append("fastboot erase misc")
    cmds.append("fastboot erase metadata")
    
    # 2. Firmware
    for img in BOOT_IMGS:
        if img in images: cmds.append(f"fastboot flash {img.split('.')[0]} images/{img}")
    
    # 3. Vbmeta (Disable checks)
    for img in VBMETA_IMGS:
        if img in images: 
            cmds.append(f"fastboot --disable-verity --disable-verification flash {img.split('.')[0]} images/{img}")

    # 4. Other firmware (dsp, modem, etc)
    for img in images:
        if img not in BOOT_IMGS and img not in VBMETA_IMGS and img != SUPER_IMG:
            part = img.split('.')[0]
            cmds.append(f"fastboot flash {part} images/{img}")

    # 5. Super
    if SUPER_IMG in images:
        cmds.append(f"fastboot flash super images/{SUPER_IMG}")

    # 6. Wipe Option
    if wipe: cmds.append("fastboot -w")
    
    cmds.append("fastboot reboot")
    if os_type == "win": cmds.append("pause")
    return cmds

# Generate Files
with open("flash_clean.bat", "w") as f:
    f.write(HEADER_BAT + "echo [!] WIPING DATA...\n" + "\n".join(get_cmds("win", True)))

with open("flash_dirty.bat", "w") as f:
    f.write(HEADER_BAT + "echo [*] Dirty Flash (Keeping Data)...\n" + "\n".join(get_cmds("win", False)))

with open("flash_clean.sh", "w") as f:
    f.write(HEADER_SH + "read -p '[!] WIPING DATA. Press Enter...' \n" + "\n".join(get_cmds("linux", True)))

with open("flash_dirty.sh", "w") as f:
    f.write(HEADER_SH + "echo '[*] Dirty Flash (Keeping Data).'\n" + "\n".join(get_cmds("linux", False)))

print("✅ Flashing scripts generated.")
