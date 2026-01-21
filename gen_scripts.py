import os
import sys

def generate_bat(device_code, images_dir):
    # The header you requested
    bat_content = f"""@echo off
cd %~dp0
set fastboot=bin\\windows\\fastboot.exe
if not exist %fastboot% echo %fastboot% not found. & pause & exit /B 1
echo Waiting for device...
set device=
for /f "tokens=2" %%A in ('%fastboot% getvar product 2^>^&1 ^| findstr "\\<product:"') do set device=%%A
if "%device%" equ "" echo Your device could not be detected. & pause & exit /B 1
echo Your device: %device%
if "%device%" neq "{device_code}" if "%device%" neq "{device_code}in" echo Compatible devices: {device_code}, {device_code}in & pause & exit /B 1

echo Your device will be flashed and the data partition will be formatted.
echo You will lose your apps, settings and files on internal storage.
echo Continue if you are flashing a custom ROM for the first time or downgrading.
set /p choice=Do you want to continue? [y/N] 
if /i "%choice%" neq "y" exit /B 0

echo ##############################################################
echo Please wait. The device will reboot once flashing is complete.
echo ##############################################################
%fastboot% set_active a
"""

    # Priority partitions (Firmware)
    # We map common names to your script's specific order/naming
    firmware_order = [
        "abl", "bluetooth", "countrycode", "devcfg", "dsp", "dtbo", "featenabler",
        "hyp", "imagefv", "keymaster", "modem", "qupfw", "rpm", "tz", 
        "uefisecapp", "vbmeta", "vbmeta_system", "vbmeta_vendor", "xbl", "xbl_config",
        "boot", "init_boot", "vendor_boot", "cust"
    ]

    files = os.listdir(images_dir)
    
    # 1. Flash Firmware (A/B slots)
    for part in firmware_order:
        img_name = f"{part}.img"
        if img_name in files:
            # Special handling for cust (usually not A/B)
            if part == "cust":
                bat_content += f"%fastboot% flash {part} images\\{img_name}\n"
            else:
                bat_content += f"%fastboot% flash {part}_ab images\\{img_name}\n"

    # 2. Flash Super (The Big One)
    if "super.img" in files:
        bat_content += "%fastboot% flash super images\\super.img\n"

    # 3. Footer
    bat_content += """%fastboot% erase metadata
%fastboot% erase userdata
%fastboot% reboot
pause
"""
    
    with open("flash_all.bat", "w") as f:
        f.write(bat_content)

def generate_sh(device_code, images_dir):
    # Minimal Linux/Mac version
    sh_content = f"""#!/bin/bash
fastboot=./bin/linux/fastboot
chmod +x $fastboot
$fastboot getvar product 2>&1 | grep "^product: {device_code}" || {{ echo "Wrong device!"; exit 1; }}
$fastboot set_active a
"""
    # Simplified loop for linux
    files = os.listdir(images_dir)
    for f in files:
        if f.endswith(".img") and f != "super.img":
            name = f.replace(".img", "")
            if name == "cust":
                sh_content += f"$fastboot flash {name} images/{f}\n"
            else:
                sh_content += f"$fastboot flash {name}_ab images/{f}\n"
    
    if "super.img" in files:
        sh_content += "$fastboot flash super images/super.img\n"

    sh_content += "$fastboot erase metadata\n$fastboot erase userdata\n$fastboot reboot\n"

    with open("flash_all.sh", "w") as f:
        f.write(sh_content)

if __name__ == "__main__":
    dev_code = sys.argv[1]
    img_dir = sys.argv[2]
    generate_bat(dev_code, img_dir)
    generate_sh(dev_code, img_dir)
    print(f"✅ Scripts generated for device: {dev_code}")
