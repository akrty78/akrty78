import os
import sys

# PARTITION LIST (Physical partitions to flash individually)
# We handle 'super' separately if it exists.
FIRMWARE_ORDER = [
    "abl", "bluetooth", "countrycode", "devcfg", "dsp", "dtbo", "featenabler",
    "hyp", "imagefv", "keymaster", "modem", "qupfw", "rpm", "tz", 
    "uefisecapp", "vbmeta", "vbmeta_system", "vbmeta_vendor", "xbl", "xbl_config",
    "boot", "init_boot", "vendor_boot", "recovery", "logo", "splash", "cust"
]

def get_windows_header(device_code, is_clean):
    mode_text = "FIRST INSTALL" if is_clean else "UPDATE ROM"
    warning = "Data partition will be formatted. You will lose all data." if is_clean else "Data partition will NOT be formatted."
    
    return f"""@echo off
cd %~dp0
set fastboot=bin\\windows\\fastboot.exe
if not exist %fastboot% echo %fastboot% not found. & pause & exit /B 1
echo Waiting for device...
set device=
for /f "tokens=2" %%A in ('%fastboot% getvar product 2^>^&1 ^| findstr "\\<product:"') do set device=%%A
if "%device%" equ "" echo Your device could not be detected. & pause & exit /B 1
echo Your device: %device%
if "%device%" neq "{device_code}" if "%device%" neq "{device_code}in" echo Compatible devices: {device_code}, {device_code}in & pause & exit /B 1

echo **************************************************************
echo                 NexDroid Fastboot Flasher
echo                  Mode: {mode_text}
echo **************************************************************
echo {warning}
echo.
set /p choice=Do you want to continue? [y/N] 
if /i "%choice%" neq "y" exit /B 0

echo.
echo Flashing Started...
%fastboot% set_active a
"""

def get_linux_header(device_code, is_clean):
    mode_text = "FIRST INSTALL" if is_clean else "UPDATE ROM"
    warning = "Data partition will be formatted." if is_clean else "Data partition will NOT be formatted."

    return f"""#!/bin/bash
# NexDroid Flasher for Linux/macOS
fastboot=./bin/linux/fastboot
[ "$(uname)" == "Darwin" ] && fastboot=./bin/macos/fastboot
chmod +x $fastboot

echo "Waiting for device..."
product=$($fastboot getvar product 2>&1 | grep "^product:" | awk '{{print $2}}')
if [ -z "$product" ]; then echo "Device not detected."; exit 1; fi

echo "Device detected: $product"
if [ "$product" != "{device_code}" ] && [ "$product" != "{device_code}in" ]; then
    echo "Error: This ROM is for {device_code}. Found $product."
    exit 1
fi

echo "------------------------------------------------"
echo " NexDroid Flasher | Mode: {mode_text}"
echo "------------------------------------------------"
echo "{warning}"
read -p "Press Enter to continue or Ctrl+C to cancel..."

$fastboot set_active a
"""

def generate_scripts(device_code, images_dir):
    files = os.listdir(images_dir)
    
    # 1. Generate Windows Scripts
    for is_clean in [True, False]:
        filename = "windows_fastboot_first_install_with_data_format.bat" if is_clean else "windows_fastboot_update_rom.bat"
        content = get_windows_header(device_code, is_clean)
        
        # Flash Firmware
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                suffix = "" if part in ["cust", "recovery", "logo", "splash"] else "_ab"
                content += f"%fastboot% flash {part}{suffix} images\\{part}.img\n"
        
        # Flash Super
        if "super.img" in files:
            content += "%fastboot% flash super images\\super.img\n"
            
        content += "%fastboot% erase metadata\n"
        if is_clean:
            content += "%fastboot% erase userdata\n"
            
        content += "%fastboot% reboot\npause\n"
        
        with open(filename, "w") as f:
            f.write(content)

    # 2. Generate Linux/Mac Scripts
    for is_clean in [True, False]:
        filename = "linux_fastboot_first_install_with_data_format.sh" if is_clean else "linux_fastboot_update_rom.sh"
        content = get_linux_header(device_code, is_clean)
        
        # Flash Firmware
        for part in FIRMWARE_ORDER:
            if f"{part}.img" in files:
                suffix = "" if part in ["cust", "recovery", "logo", "splash"] else "_ab"
                content += f"$fastboot flash {part}{suffix} images/{part}.img\n"
        
        # Flash Super
        if "super.img" in files:
            content += "$fastboot flash super images/super.img\n"
            
        content += "$fastboot erase metadata\n"
        if is_clean:
            content += "$fastboot erase userdata\n"
            
        content += "$fastboot reboot\n"
        
        with open(filename, "w") as f:
            f.write(content)

if __name__ == "__main__":
    generate_scripts(sys.argv[1], sys.argv[2])
    print(f"✅ Generated 4 flashing scripts for {sys.argv[1]}")
