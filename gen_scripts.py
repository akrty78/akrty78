import os
import sys

FIRMWARE_ORDER = [
    "abl", "bluetooth", "countrycode", "devcfg", "dsp", "dtbo", "featenabler",
    "hyp", "imagefv", "keymaster", "modem", "qupfw", "rpm", "tz", 
    "uefisecapp", "vbmeta", "vbmeta_system", "vbmeta_vendor", "xbl", "xbl_config",
    "boot", "init_boot", "vendor_boot", "recovery", "logo", "splash", "cust"
]

def get_header(device_code, is_clean, is_windows):
    mode = "CLEAN INSTALL (WIPE DATA)" if is_clean else "UPDATE ROM (KEEP DATA)"
    
    if is_windows:
        warning = "Your Data Partition will be ERASED!" if is_clean else "Your Data will be preserved."
        return f"""@echo off
cd %~dp0
set fastboot=bin\\windows\\fastboot.exe
if not exist %fastboot% echo Fastboot not found. & pause & exit /B 1
echo ------------------------------------------
echo  NexDroid Flasher | {mode}
echo  Device: {device_code}
echo ------------------------------------------
echo {warning}
echo.
set /p c=Continue? [y/N] 
if /i "%c%" neq "y" exit /B 0
%fastboot% set_active a
"""
    else:
        warning = "Your Data Partition will be ERASED!" if is_clean else "Your Data will be preserved."
        return f"""#!/bin/bash
fastboot=./bin/linux/fastboot
[ "$(uname)" == "Darwin" ] && fastboot=./bin/macos/fastboot
chmod +x $fastboot
echo "------------------------------------------"
echo " NexDroid Flasher | {mode}"
echo "------------------------------------------"
echo "{warning}"
read -p "Press Enter to continue..."
$fastboot set_active a
"""

def generate_scripts(device_code, images_dir):
    files = os.listdir(images_dir)
    
    for is_clean in [True, False]:
        # --- WINDOWS ---
        name = f"windows_fastboot_{'first_install_with_data_format' if is_clean else 'update_rom'}.bat"
        content = get_header(device_code, is_clean, True)
        
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                suffix = "" if part in ["cust", "recovery", "logo", "splash"] else "_ab"
                content += f"%fastboot% flash {part}{suffix} images\\{part}.img\n"

        if "super.img" in files:
            content += "\necho Flashing Super (May take 5-10 mins)...\n"
            content += "%fastboot% flash super images\\super.img\n"
        
        content += "\n%fastboot% erase metadata\n"
        if is_clean: content += "%fastboot% erase userdata\n"
        content += "%fastboot% reboot\npause\n"
        with open(name, "w") as f: f.write(content)

        # --- LINUX / MAC ---
        name = f"linux_fastboot_{'first_install_with_data_format' if is_clean else 'update_rom'}.sh"
        content = get_header(device_code, is_clean, False)
        
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                suffix = "" if part in ["cust", "recovery", "logo", "splash"] else "_ab"
                content += f"$fastboot flash {part}{suffix} images/{part}.img\n"

        if "super.img" in files:
            content += "echo 'Flashing Super...'\n"
            content += "$fastboot flash super images/super.img\n"

        content += "$fastboot erase metadata\n"
        if is_clean: content += "$fastboot erase userdata\n"
        content += "$fastboot reboot\n"
        with open(name, "w") as f: f.write(content)

if __name__ == "__main__":
    generate_scripts(sys.argv[1], sys.argv[2])
