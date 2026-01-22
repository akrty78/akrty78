import os
import sys
import subprocess
import shutil
import re

RULES = [{
    "apk_name": "Provision.apk",
    # Using 'r' prefix fixes the SyntaxWarning
    "search_pattern": r"sget-boolean\s+([vp]\d+),\s*Lmiui\/os\/Build;->IS_INTERNATIONAL_BUILD:Z",
    "replace_code": r"const/4 \g<1>, 0x1" 
}]

def run_cmd(cmd):
    try:
        if not shutil.which(cmd[0]): return False
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return True
    except: return False

def patch_file(file_path, search_regex, replace_str):
    with open(file_path, 'r', encoding='utf-8') as f: content = f.read()
    match = re.search(search_regex, content)
    if match:
        print(f"            - Match found: {match.group(0)}")
        new_content = re.sub(search_regex, replace_str, content)
        if new_content != content:
            with open(file_path, 'w', encoding='utf-8') as f: f.write(new_content)
            print(f"            + Replaced with: {replace_str}")
            return True
    return False

def process_apk(apk_path, rule):
    print(f"      🔧 Processing: {apk_path}")
    temp_dir = apk_path + "_temp"
    if os.path.exists(temp_dir): shutil.rmtree(temp_dir)
    
    if not run_cmd(["apktool", "d", "-f", apk_path, "-o", temp_dir]):
        print("         ⚠️  Decompile failed."); return

    patched = False
    for root, dirs, files in os.walk(temp_dir):
        for file in files:
            if file.endswith(".smali"):
                if patch_file(os.path.join(root, file), rule["search_pattern"], rule["replace_code"]):
                    print(f"         ✅ PATCH SUCCESS: {file}")
                    patched = True
    
    if patched:
        if os.path.exists(apk_path): os.remove(apk_path)
        if run_cmd(["apktool", "b", temp_dir, "-o", apk_path]):
            if os.path.exists("testkey.pk8"):
                run_cmd(["apksigner", "sign", "--key", "testkey.pk8", "--cert", "testkey.x509.pem", apk_path])
                print("         ✨ Signed & Saved")
            else: print("         ⚠️  Unsigned (No Keys)")
        else: print("         ❌ Recompile Failed")
    else: print("         ⚠️  Pattern not found")
    
    shutil.rmtree(temp_dir)

def main(partition_root):
    print(f"      🔍 Scanning {partition_root}...")
    for rule in RULES:
        target = rule["apk_name"].lower()
        for root, dirs, files in os.walk(partition_root):
            for file in files:
                if file.lower() == target: process_apk(os.path.join(root, file), rule)

if __name__ == "__main__":
    if len(sys.argv) > 1: main(sys.argv[1])
