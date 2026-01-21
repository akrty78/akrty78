import os
import sys

def generate_bat(device_code, images_dir):
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

echo Your device will be flashed (Firmware Only).
echo Data partition will NOT be touched.
echo Continue?
set /p choice=Do you want to continue? [y/N] 
if /i "%choice%" neq "y" exit /B 0

echo ##############################################################
echo Flashing Firmware...
echo ##############################################################
%fastboot% set_active a
"""

    # The exact list from your request
    firmware_order = [
        "abl", "bluetooth", "countrycode", "devcfg", "dsp", "dtbo", "featenabler",
        "hyp", "imagefv", "keymaster", "modem", "qupfw", "rpm", "tz", 
        "uefisecapp", "vbmeta", "vbmeta_system", "vbmeta_vendor", "xbl", "xbl_config",
        "boot", "init_boot", "vendor_boot", "recovery", "logo", "splash", "cust"
    ]

    files = os.listdir(images_dir)
    
    for part in firmware_order:
        img_name = f"{part}.img"
        if img_name in files:
            # Special handling: cust usually isn't A/B
            if part in ["cust", "logo", "splash", "recovery"]:
                bat_content += f"%fastboot% flash {part} images\\{img_name}\n"
            else:
                bat_content += f"%fastboot% flash {part}_ab images\\{img_name}\n"

    bat_content += """
echo.
echo Flashing Complete.
%fastboot% reboot
pause
"""
    
    with open("flash_all.bat", "w") as f:
        f.write(bat_content)

if __name__ == "__main__":
    dev_code = sys.argv[1]
    img_dir = sys.argv[2]
    generate_bat(dev_code, img_dir)
    print(f"✅ Firmware Scripts generated for: {dev_code}")
