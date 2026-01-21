import os
import sys

# PARTITION LIST
FIRMWARE_ORDER = [
    "abl", "bluetooth", "countrycode", "devcfg", "dsp", "dtbo", "featenabler",
    "hyp", "imagefv", "keymaster", "modem", "qupfw", "rpm", "tz", 
    "uefisecapp", "vbmeta", "vbmeta_system", "vbmeta_vendor", "xbl", "xbl_config",
    "boot", "init_boot", "vendor_boot", "recovery", "logo", "splash", "cust"
]

def get_header(device_code, is_clean, is_windows):
    mode = "FIRST INSTALL" if is_clean else "UPDATE ROM"
    warning = "Data will be wiped!" if is_clean else "Data will be kept."
    
    if is_windows:
        return f"""@echo off
cd %~dp0
set fastboot=bin\\windows\\fastboot.exe
if not exist %fastboot% echo Fastboot not found. & pause & exit /B 1
echo ------------------------------------------
echo  NexDroid Flasher | {mode}
echo  Device Code: {device_code}
echo ------------------------------------------
echo {warning}
echo.
set /p c=Continue? [y/N] 
if /i "%c%" neq "y" exit /B 0
%fastboot% set_active a
"""
    else:
        return f"""#!/bin/bash
fastboot=./bin/linux/fastboot
[ "$(uname)" == "Darwin" ] && fastboot=./bin/macos/fastboot
chmod +x $fastboot
echo "------------------------------------------"
echo " NexDroid Flasher | {mode}"
echo "------------------------------------------"
echo "{warning}"
read -p "Press Enter..."
$fastboot set_active a
"""

def generate_scripts(device_code, images_dir):
    files = os.listdir(images_dir)
    
    # Generate Windows & Linux Scripts
    for is_clean in [True, False]:
        # WINDOWS
        ext = "bat"
        name = f"windows_fastboot_{'clean' if is_clean else 'update'}.{ext}"
        content = get_header(device_code, is_clean, True)
        
        # 1. Flash Firmware
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                # Cust/Recovery/Logo are usually single slot
                suffix = "" if part in ["cust", "recovery", "logo", "splash"] else "_ab"
                content += f"%fastboot% flash {part}{suffix} images\\{part}.img\n"

        # 2. Flash Super (CRITICAL CHECK)
        if "super.img" in files:
            content += "\necho Flashing Super (This takes a while)...\n"
            content += "%fastboot% flash super images\\super.img\n"
        else:
            content += "\n:: WARNING: super.img not found!\n"

        # 3. Wipe & Reboot
        content += "\n%fastboot% erase metadata\n"
        if is_clean: content += "%fastboot% erase userdata\n"
        content += "%fastboot% reboot\npause\n"
        
        with open(
