import os
import sys
import subprocess
import shutil
import re

# =========================================================
# ⚙️ PATCHING RULES
# Define what APKs to hack and what to change.
# =========================================================
RULES = [
    {
        "apk_name": "Provision.apk",
        "target_smali": "widget.smali",  # The file containing the code
        "search_pattern": r"sget-boolean ([vp]\d+), Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z",
        "replace_code": "const/4 \g<1>, 0x1" # \g<1> preserves the register (v0, v1, etc.)
    }
]

# =========================================================

def run_cmd(cmd):
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        print(f"      ❌ Error running command: {' '.join(cmd)}")
        print(f"      Error details: {e.stderr.decode()}")
        return False
    return True

def patch_file(file_path, search_regex, replace_str):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check if the pattern exists before trying to replace
    if re.search(search_regex, content):
        new_content = re.sub(search_regex, replace_str, content)
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        return True
    return False

def process_apk(apk_path, rule):
    print(f"      🔧 Patching {os.path.basename(apk_path)}...")
    
    # 1. Decompile
    temp_dir = apk_path + "_temp"
    if os.path.exists(temp_dir): shutil.rmtree(temp_dir)
    
    if not run_cmd(["apktool", "d", "-f", apk_path, "-o", temp_dir]):
        return

    # 2. Hunt & Patch
    patched = False
    for root, dirs, files in os.walk(temp_dir):
        for file in files:
            if file == rule["target_smali"]:
                full_path = os.path.join(root, file)
                if patch_file(full_path, rule["search_pattern"], rule["replace_code"]):
                    print(f"         ✅ Patched: {file}")
                    patched = True
                    break # Stop looking if we found and patched it
        if patched: break

    if not patched:
        print(f"         ⚠️  Target code not found in {os.path.basename(apk_path)}")
        shutil.rmtree(temp_dir)
        return

    # 3. Recompile
    # We rename original to .bak just in case
    shutil.move(apk_path, apk_path + ".bak")
    
    if not run_cmd(["apktool", "b", temp_dir, "-o", apk_path]):
        print("         ❌ Recompile Failed!")
        shutil.move(apk_path + ".bak", apk_path) # Restore original
        shutil.rmtree(temp_dir)
        return

    # 4. Sign (Essential for system apps to run)
    # Using a debug key is usually fine for modded ROMs with signature checks disabled
    print("         ✍️  Signing...")
    run_cmd(["apksigner", "sign", "--key", "testkey.pk8", "--cert", "testkey.x509.pem", apk_path])
    
    # Clean up
    shutil.rmtree(temp_dir)
    if os.path.exists(apk_path + ".bak"): os.remove(apk_path + ".bak")
    print(f"         ✨ Success! Overwrote {os.path.basename(apk_path)}")

def main(partition_root):
    # Scan the partition dump for any APKs matching our rules
    for rule in RULES:
        # We look in app, priv-app, and their subfolders
        target_name = rule["apk_name"]
        found_paths = subprocess.getoutput(f'find {partition_root} -name "{target_name}"').splitlines()
        
        for path in found_paths:
            if os.path.isfile(path):
                process_apk(path, rule)

if __name__ == "__main__":
    # Create dummy test keys if they don't exist (needed for signing)
    if not os.path.exists("testkey.pk8"):
        # Generate a quick generic key (requires openssl/keytool, usually on build servers)
        # For simplicity, we assume the environment can sign or we use a basic debug key generation
        # If this fails, standard 'apksigner' might have a default debug key
        pass 
    
    main(sys.argv[1])
