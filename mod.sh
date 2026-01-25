#!/usr/bin/env bash
# =========================================================
#  NEXDROID HYPEROS – CLEAN & DETERMINISTIC PIPELINE
#  CI-safe | Context-safe | Proper signing | Real super.img
# =========================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG ----------------
ROM_URL="$1"
WORKDIR="$PWD/work"
TOOLS="$WORKDIR/tools"
OUT="$WORKDIR/out"
MNT="$WORKDIR/mnt"
GAPPS_DIR="$WORKDIR/gapps"
KEYS="$WORKDIR/keys"

PARTS=(system system_ext product vendor odm mi_ext)

DEBLOAT_PATHS=(
  "product/app/MiuiVideo"
  "product/app/MiuiMusic"
  "product/app/Browser"
  "product/priv-app/MiuiSystemAds"
)

# ---------------- SETUP ----------------
mkdir -p "$WORKDIR" "$TOOLS" "$OUT" "$MNT"
export PATH="$TOOLS:$PATH"

apt-get update -y
apt-get install -y \
  erofs-utils \
  fuse3 \
  lz4 \
  jq \
  zip unzip \
  aria2 \
  python3 \
  openjdk-17-jdk \
  aapt \
  apksigner

# ---------------- EROFS FUSE DETECTION ----------------
if command -v erofsfuse >/dev/null 2>&1; then
  EROFS_FUSE="erofsfuse"
elif command -v fuse.erofs >/dev/null 2>&1; then
  EROFS_FUSE="fuse.erofs"
else
  echo "❌ No EROFS FUSE binary found (erofsfuse / fuse.erofs)"
  exit 1
fi

echo "✅ Using EROFS fuse: $EROFS_FUSE"

# ---------------- TOOLS ----------------
if ! command -v payload-dumper-go &>/dev/null; then
  curl -L https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz | tar xz
  mv payload-dumper-go "$TOOLS/"
  chmod +x "$TOOLS/payload-dumper-go"
fi

# ---------------- DOWNLOAD ROM ----------------
cd "$WORKDIR"
aria2c -x16 "$ROM_URL" -o rom.zip
unzip -q rom.zip payload.bin
payload-dumper-go -o images payload.bin

# ---------------- EXTRACT PARTITIONS ----------------
for p in "${PARTS[@]}"; do
  IMG="images/$p.img"
  [ ! -f "$IMG" ] && continue

  echo "🔓 Extracting $p"
  mkdir -p "$WORKDIR/$p"

  "$EROFS_FUSE" "$IMG" "$MNT"
  cp -a "$MNT/." "$WORKDIR/$p/"
  fusermount -u "$MNT"

  rm -f "$IMG"
done

# ---------------- SAFE DEBLOAT ----------------
for path in "${DEBLOAT_PATHS[@]}"; do
  for p in "${PARTS[@]}"; do
    TARGET="$WORKDIR/$p/$path"
    [ -d "$TARGET" ] && rm -rf "$TARGET"
  done
done

# ---------------- GApps INSTALL ----------------
for app in "$GAPPS_DIR/app"/*; do
  name=$(basename "$app")
  mkdir -p "$WORKDIR/product/app/$name"
  cp "$app"/*.apk "$WORKDIR/product/app/$name/"
done

for app in "$GAPPS_DIR/priv-app"/*; do
  name=$(basename "$app")
  mkdir -p "$WORKDIR/product/priv-app/$name"
  cp "$app"/*.apk "$WORKDIR/product/priv-app/$name/"
done

mkdir -p "$WORKDIR/product/etc/permissions"
cp "$GAPPS_DIR/permissions"/*.xml "$WORKDIR/product/etc/permissions/"

# ---------------- SIGN PRIV-APPS ----------------
for apk in $(find "$WORKDIR/product/priv-app" -name "*.apk"); do
  apksigner sign \
    --key "$KEYS/platform.pk8" \
    --cert "$KEYS/platform.x509.pem" \
    "$apk"
done

# ---------------- PROPERTIES ----------------
cat >> "$WORKDIR/product/etc/build.prop" <<EOF
ro.miui.has_gmscore=1
persist.sys.gms.enabled=1
EOF

# ---------------- REPACK EROFS ----------------
for p in "${PARTS[@]}"; do
  [ ! -d "$WORKDIR/$p" ] && continue
  mkfs.erofs --preserve-xattr "$OUT/$p.img" "$WORKDIR/$p"
done

# ---------------- BUILD SUPER ----------------
SUPER_SIZE=$(du -sb "$OUT"/*.img | awk '{s+=$1} END {print int(s*1.15)}')

lpmake \
  --metadata-size 65536 \
  --super-name super \
  --device super:$SUPER_SIZE \
  $(for p in "${PARTS[@]}"; do echo "--partition $p:readonly:0:super --image $p=$OUT/$p.img"; done) \
  --output "$OUT/super.img"

# ---------------- FLASH ZIP ----------------
cd "$OUT"
zip -r Firmware.zip super.img

echo "✅ BUILD COMPLETE"
