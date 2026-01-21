import os
import sys

# Critical Firmware Partitions (Flashed to both slots _ab)
FIRMWARE_ORDER = [
    "abl", "bluetooth", "countrycode", "devcfg", "dsp", "dtbo", "featenabler",
    "hyp", "imagefv", "keymaster", "modem", "qupfw", "rpm", "tz", 
    "uefisecapp", "vbmeta", "vbmeta_system", "vbmeta_vendor", "xbl", "xbl_config",
    "boot", "init_boot", "vendor_boot"
]

# Non-A/B Partitions (Flashed to active slot only)
SINGLE_SLOT_PARTS = ["cust", "recovery", "logo", "splash", "persist", "misc"]

def get_header(device_code, is_clean, is_windows):
    mode = "CLEAN INSTALL (WIPE DATA)" if is_clean else "UPDATE ROM (KEEP DATA)"
    
    if is_windows:
        warning = "Your Data Partition will be ERASED!" if is_clean else "Your Data will be preserved."
        return f"""@echo off
cd /d "%~dp0"
set "fastboot=bin\\windows\\fastboot.exe"
if not exist "%fastboot%" (
    echo Fastboot tool not found in bin\\windows\\
    pause
    exit /B 1
)

echo ------------------------------------------
echo  NexDroid Flasher | {mode}
echo  Device: {device_code}
echo ------------------------------------------
echo {warning}
echo.
set /p c=Are you sure you want to continue? [y/N]: 
if /i "%c%" neq "y" exit /B 0

echo.
echo Setting active slot to A...
"%fastboot%" set_active a
if errorlevel 1 ( echo Failed to set active slot & pause & exit /B 1 )
"""
    else:
        warning = "Your Data Partition will be ERASED!" if is_clean else "Your Data will be preserved."
        return f"""#!/bin/bash
cd "$(dirname "$0")"
fastboot="./bin/linux/fastboot"
if [ "$(uname)" == "Darwin" ]; then
    fastboot="./bin/macos/fastboot"
fi

if [ ! -f "$fastboot" ]; then
    echo "Fastboot tool not found in bin/"
    exit 1
fi

chmod +x "$fastboot"

echo "------------------------------------------"
echo " NexDroid Flasher | {mode}"
echo "------------------------------------------"
echo "{warning}"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

echo "Setting active slot to A..."
"$fastboot" set_active a
if [ $? -ne 0 ]; then echo "Failed to set slot"; exit 1; fi
"""

def generate_scripts(device_code, images_dir):
    # Ensure we are looking at the right files
    if not os.path.exists(images_dir):
        print(f"Error: Images directory '{images_dir}' not found.")
        return

    files = os.listdir(images_dir)
    print(f"Generating scripts for {device_code} with {len(files)} images...")

    for is_clean in [True, False]:
        # ==========================================
        # WINDOWS SCRIPT GENERATION
        # ==========================================
        name_win = f"windows_fastboot_{'first_install_with_data_format' if is_clean else 'update_rom'}.bat"
        content_win = get_header(device_code, is_clean, True)
        
        # 1. Flash Firmware & Boot
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                # Flash to both slots (_ab) for safety on these partitions
                content_win += f'echo Flashing {part}...\n'
                content_win += f'"%fastboot%" flash {part}_ab "images\\{part}.img"\n'
                content_win += f'if errorlevel 1 ( echo Error flashing {part} & pause & exit /B 1 )\n'

        # 2. Flash Single Slot Partitions (Recovery, etc)
        for part in SINGLE_SLOT_PARTS:
            if f"{part}.img" in files:
                content_win += f'echo Flashing {part}...\n'
                content_win += f'"%fastboot%" flash {part} "images\\{part}.img"\n'
                content_win += f'if errorlevel 1 ( echo Error flashing {part} & pause & exit /B 1 )\n'

        # 3. Flash Super
        if "super.img" in files:
            content_win += "\necho Flashing Super (This may take 5-10 minutes)...\n"
            content_win += '"%fastboot%" flash super "images\\super.img"\n'
            content_win += 'if errorlevel 1 ( echo Error flashing super & pause & exit /B 1 )\n'
        
        # 4. Finalize
        content_win += "\n%fastboot% erase metadata\n"
        if is_clean: 
            content_win += 'echo Wiping Userdata...\n'
            content_win += "%fastboot% erase userdata\n"
        
        content_win += "\necho ------------------------------------------\n"
        content_win += "echo Flashing Complete! Rebooting...\n"
        content_win += "%fastboot% reboot\n"
        content_win += "pause\n"
        
        with open(name_win, "w") as f: f.write(content_win)


        # ==========================================
        # LINUX / MAC SCRIPT GENERATION
        # ==========================================
        name_lin = f"linux_fastboot_{'first_install_with_data_format' if is_clean else 'update_rom'}.sh"
        content_lin = get_header(device_code, is_clean, False)
        
        # 1. Flash Firmware & Boot
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                content_lin += f'echo "Flashing {part}..."\n'
                content_lin += f'"$fastboot" flash {part}_ab "images/{part}.img"\n'
                content_lin += f'if [ $? -ne 0 ]; then echo "Error flashing {part}"; exit 1; fi\n'

        # 2. Flash Single Slot Partitions
        for part in SINGLE_SLOT_PARTS:
            if f"{part}.img" in files:
                content_lin += f'echo "Flashing {part}..."\n'
                content_lin += f'"$fastboot" flash {part} "images/{part}.img"\n'
                content_lin += f'if [ $? -ne 0 ]; then echo "Error flashing {part}"; exit 1; fi\n'

        # 3. Flash Super
        if "super.img" in files:
            content_lin += '\necho "Flashing Super (This may take 5-10 minutes)..."\n'
            content_lin += '"$fastboot" flash super "images/super.img"\n'
            content_lin += 'if [ $? -ne 0 ]; then echo "Error flashing super"; exit 1; fi\n'

        # 4. Finalize
        content_lin += '\n"$fastboot" erase metadata\n'
        if is_clean: 
            content_lin += 'echo "Wiping Userdata..."\n'
            content_lin += '"$fastboot" erase userdata\n'
        
        content_lin += '\necho "------------------------------------------"\n'
        content_lin += 'echo "Flashing Complete! Rebooting..."\n'
        content_lin += '"$fastboot" reboot\n'
        
        with open(name_lin, "w") as f: f.write(content_lin)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 gen_scripts.py <device_code> <images_dir>")
        sys.exit(1)
    generate_scripts(sys.argv[1], sys.argv[2])
