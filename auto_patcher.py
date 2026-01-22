import os
import sys
import subprocess
import shutil
import re

# =========================================================
# ⚙️ PATCHING RULES
# =========================================================
RULES = [
    {
        "apk_name": "Provision.apk",
        # removed "target_smali" - we now scan EVERYTHING
        "search_pattern": r"sget-boolean\s+([vp]\d+),\s*Lmiui/os/Build;->IS_INTERNATIONAL_BUILD:Z",
        "replace_code": "const/4 \g<1>, 0x1"
    }
]

# =========================================================

def run_cmd(cmd):
    try:
        tool = cmd[0]
        if not shutil.which(tool):
            print(f"         ❌ Error: '{tool}' not found in PATH.")
            return False
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return True
    except subprocess.CalledProcessError as e:
        print(f"      ❌ Command Failed: {' '.join(cmd)}")
        # print(f"      Log: {e.stderr.decode()[:200]}...") 
        return False

def patch_file(file_path, search_regex, replace_str):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check if pattern exists (Regex search)
    match = re.search(search_regex, content)
    if match:
        print(f"         🔎 Found match in: {os.path.basename(file_path)}")
        # Perform substitution
        new_content = re.sub(search_regex, replace_str, content)
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        return True
    return False

def process_apk(apk_path, rule):
    print(f"      🔧 Processing {os.path.basename(apk_path)}...")
    
    # 1. Decompile
    temp_dir = apk_path + "_temp"
    if os.path.exists(temp_dir): shutil.rmtree(temp_dir)
    
    # Try generic apktool first, if fail, try with --no-src to handle weird resources
    if not run_cmd(["apktool", "d", "-f", apk_path, "-o", temp_dir]):
        print("         ⚠️  Decompile failed (Resources issue?). Skipping.")
        return

    # 2. Hunt & Patch (SCAN ALL SMALI FILES)
    patched = False
    for root, dirs, files in os.walk(temp_dir):
        for file in files:
            if file.endswith(".smali"):
                full_path = os.path.join(root, file)
                # We check EVERY smali file now
                if patch_file(full_path, rule["search_pattern"], rule["replace_code"]):
                    print(f"         ✅ PATCH APPLIED: {file}")
                    patched = True
                    # We don't break immediately in case there are multiple occurrences
                    # break 

    if not patched:
        print(f"         ⚠️  Pattern not found in {os.path.basename(apk_path)} (Is the regex correct?)")
        shutil.rmtree(temp_dir)
        return

    # 3. Recompile
    if os.path.exists(apk_path): os.remove(apk_path)
    
    if not run_cmd(["apktool", "b", temp_dir, "-o", apk_path]):
        print("         ❌ Recompile Failed (Smali Syntax Error?)")
        shutil.rmtree(temp_dir)
        return

    # 4. Sign
    if os.path.exists("testkey.pk8") and os.path.exists("testkey.x509.pem"):
        run_cmd(["apksigner", "sign", "--key", "testkey.pk8", "--cert", "testkey.x509.pem", apk_path])
        print("         ✨ Signed & Saved")
    else:
        print("         ⚠️  Signing Keys Missing! APK will be unsigned.")
    
    shutil.rmtree(temp_dir)

def main(partition_root):
    print(f"      🔍 Scanning {partition_root} for target APKs...")
    
    for rule in RULES:
        target_lower = rule["apk_name"].lower()
        found_apks = []

        # Find all instances of the APK
        for root, dirs, files in os.walk(partition_root):
            for file in files:
                if file.lower() == target_lower:
                    found_apks.append(os.path.join(root, file))
        
        if not found_apks:
            print(f"      ⚠️  APK '{rule['apk_name']}' not found in partition.")
        
        for apk_path in found_apks:
            process_apk(apk_path, rule)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        main(sys.argv[1])
    else:
        print("Usage: python3 auto_patcher.py <partition_dump_folder>")
        
