import os
import shutil
import sys

# === CONFIGURATION ===
GAPPS_SRC = "gapps"
PERM_SRC = "permissions"
NUKE_FILE = "nuke.txt"

# APPS TO INJECT
PRODUCT_APP_APKS = ["GoogleTTS.apk", "SoundPickerGoogle.apk", "LatinImeGoogle.apk", "MiuiBiometric.apk", "GeminiShell.apk"]
PRODUCT_PRIV_APP_APKS = [
    "AndroidAutoStub.apk", "GoogleRestore.apk", "GooglePartnerSetup.apk",
    "Assistant.apk", "HotwordEnrollmentYGoogleRISCV_WIDEBAND.apk",
    "Velvet.apk", "Phonesky.apk", "MIUIPackageInstaller.apk"
]
EXT_APP_APKS = ["Wizard.apk"]

# PERMISSIONS MAPPING
PERMISSIONS_MAP = {
    "default-permissions-google.xml": "product/etc/default-permissions",
    "split-permissions-google.xml": "product/etc/permissions",
    "privapp-permissions-miui-product.xml": "product/etc/permissions",
    "privapp-permissions-microsoft-product.xml": "product/etc/permissions",
    "privapp-permissions-gms-international-product.xml": "product/etc/permissions",
    "com.google.android.apps.googleassistant.xml": "product/etc/permissions",
    "privapp-permissions-deviceintegrationservice.xml": "product/etc/permissions",
    "cn.google.services.xml": "product/etc/permissions",
    "com.google.android.googlequicksearchbox.xml": "product/etc/permissions",
    "com.android.vending": "product/etc/permissions",
    "google.xml": "product/etc/sysconfig",
    "google_build.xml": "product/etc/sysconfig",
    "google_exclusives_enable.xml": "product/etc/sysconfig",
    "google-hiddenapi-package-allowlist.xml": "product/etc/sysconfig",
    "google-initial-package-stopped-states.xml": "product/etc/sysconfig",
    "google-staged-installer-whitelist.xml": "product/etc/sysconfig",
    "initial-package-stopped-states-aosp.xml": "product/etc/sysconfig",
    "microsoft.xml": "product/etc/sysconfig",
    "preinstalled-packages-platform-handheld-product.xml": "product/etc/sysconfig",
    "preinstalled-packages-platform-overlays.xml": "product/etc/sysconfig",
    "preinstalled-packages-platform-telephony-product.xml": "product/etc/sysconfig",
    "sysconfig_contextual_search.xml": "product/etc/sysconfig",
    "xmscore.config.xml": "product/etc/sysconfig",
    "google_aicore.xml": "product/etc/sysconfig",
    "gemini_shell.xml": "product/etc/sysconfig",
    "cross_device_services.xml": "product/etc/sysconfig",
}

# CUSTOM PROPS TO INJECT
CUSTOM_PROPS = """
# === NEXDROID CUSTOM PROPS ===
ro.miui.support_super_clipboard=1
persist.sys.support_super_clipboard=1
ro.miui.support.system.app.uninstall.v2=true
ro.vendor.audio.sfx.harmankardon=1
vendor.audio.lowpower=false
ro.vendor.audio.feature.spatial=7
debug.sf.disable_backpressure=1
debug.sf.latch_unsignaled=1
ro.surface_flinger.use_content_detection_for_refresh_rate=true
ro.HOME_APP_ADJ=1
persist.sys.purgeable_assets=1
persist.service.pcsync.enable=0
persist.service.lgospd.enable=0
ro.config.zram=true
dalvik.vm.heapgrowthlimit=128m
dalvik.vm.heapsize=256m
dalvik.vm.execution-mode=int:jit
persist.vendor.sys.memplus.enable=true
wifi.supplicant_scan_interval=180
ro.config.hw_power_saving=1
persist.radio.add_power_save=1
pm.sleep_mode=1
ro.ril.disable.power.collapse=0
doze.display.supported=true
persist.vendor.night.charge=true
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
persist.logd.limit=OFF
ro.logdumpd.enabled=0
ro.lmk.debug=false
profiler.force_disable_err_rpt=1
ro.miui.has_gmscore=1
ro.control.privapp_permissions=
"""

def nuke_bloat(partition_root):
    if not os.path.exists(NUKE_FILE): return
    print("      🗑️  Running Debloater...")
    with open(NUKE_FILE) as f:
        bloat_list = [line.strip() for line in f if line.strip()]
    
    for app in bloat_list:
        found = False
        for root, dirs, files in os.walk(partition_root):
            if app in dirs:
                shutil.rmtree(os.path.join(root, app))
                print(f"         - Nuked: {app}")
                found = True
        if not found:
            pass # Silent skip

def inject_apks(partition_root):
    print("      📦 Injecting GApps...")
    
    def install(apk, folder_type):
        src = os.path.join(GAPPS_SRC, apk)
        if not os.path.exists(src): return
        
        # Determine path
        if folder_type == "priv": base = os.path.join(partition_root, "product/priv-app")
        else: base = os.path.join(partition_root, "product/app")
        
        dest = os.path.join(base, apk.replace(".apk", ""))
        os.makedirs(dest, exist_ok=True)
        shutil.copy(src, os.path.join(dest, apk))
        print(f"         + Installed: {apk}")

    for apk in PRODUCT_APP_APKS: install(apk, "app")
    for apk in PRODUCT_PRIV_APP_APKS: install(apk, "priv")
    for apk in EXT_APP_APKS: install(apk, "app") # Fallback to app

def inject_perms(partition_root):
    print("      🔑 Injecting Permissions...")
    for xml, rel_path in PERMISSIONS_MAP.items():
        src = os.path.join(PERM_SRC, xml)
        if os.path.exists(src):
            dest_dir = os.path.join(partition_root, rel_path)
            os.makedirs(dest_dir, exist_ok=True)
            shutil.copy(src, dest_dir)

def inject_props(partition_root):
    print("      🚀 Injecting Props...")
    for root, dirs, files in os.walk(partition_root):
        if "build.prop" in files:
            prop_path = os.path.join(root, "build.prop")
            with open(prop_path, "a") as f:
                f.write(CUSTOM_PROPS)
            print(f"         + Patched: {prop_path}")

def main(partition_root):
    nuke_bloat(partition_root)
    inject_props(partition_root)
    
    # Only inject GApps into the Product partition
    # (Check if product folder exists in root)
    if os.path.exists(os.path.join(partition_root, "product")):
        inject_apks(partition_root)
        inject_perms(partition_root)

if __name__ == "__main__":
    main(sys.argv[1])
