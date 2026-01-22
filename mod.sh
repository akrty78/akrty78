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
        # Regex explanation:
        # sget-boolean  -> Match instruction
        # \s+           -> Match one or more spaces
        # ([vp]\d+)     -> Capture the register (v0, v1, p0, etc) as Group 1
        # ,\s* -> Match comma and optional space
        # Lmiui...      -> Match the specific class path
        "search_pattern": r"sget-boolean\s+([vp]\d+),\s*Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z",
        
        # Replacement:
        # const/4       -> New instruction
        # \g<1>         -> Insert the captured register (e.g., v0)
        # , 0x1         -> Set to True
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
        return False

def patch_file(file_path, search_regex, replace_str):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Check if pattern exists
    match = re.search(search_regex, content)
    if match:
        print(f"         🔎 Found target code in: {os.path.basename(file_path)}")
        print(f"            - Match: {match.group(0)}")
        
        # Perform substitution
        new_content = re.sub(search_regex, replace_str, content)
        
        # Verify substitution happened
        if new_content != content:
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            print(f"            + Replaced with: const/4 {match.group(1)}, 0x1")
            return True
    return False

def process_apk(apk_path, rule):
    print(f"      🔧 Processing {os.path.basename(apk_path)}...")
    
    # 1. Decompile
    temp_dir = apk_path + "_temp"
    if os.path.exists(temp_dir): shutil.rmtree(temp_dir)
    
    if not run_cmd(["apktool", "d", "-f", apk_path, "-o", temp_dir]):
        print("         ⚠️  Decompile failed.")
        return

    # 2. Hunt & Patch (SCAN ALL SMALI FILES)
    patched = False
    for root, dirs, files in os.walk(temp_dir):
        for file in files:
            if file.endswith(".smali"):
                full_path = os.path.join(root, file)
                if patch_file(full_path, rule["search_pattern"], rule["replace_code"]):
                    print(f"         ✅ PATCH SUCCESS: {file}")
                    patched = True
                    # We continue scanning in case the check appears multiple times
    
    if not patched:
        print(f"         ⚠️  Pattern not found in {os.path.basename(apk_path)}")
        shutil.rmtree(temp_dir)
        return

    # 3. Recompile
    if os.path.exists(apk_path): os.remove(apk_path)
    
    if not run_cmd(["apktool", "b", temp_dir, "-o", apk_path]):
        print("         ❌ Recompile Failed")
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
        found = False
        
        for root, dirs, files in os.walk(partition_root):
            for file in files:
                if file.lower() == target_lower:
                    process_apk(os.path.join(root, file), rule)
                    found = True
        
        if not found:
            print(f"      ⚠️  APK '{rule['apk_name']}' not found in partition.")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        main(sys.argv[1])
    else:
        print("Usage: python3 auto_patcher.py <partition_dump_folder>")
