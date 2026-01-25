#!/usr/bin/env bash
# =========================================================
#  NEXDROID HYPEROS – FINAL DETERMINISTIC PIPELINE
#  CI-safe | Root-safe | Proper signing | Real super.img
# =========================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------- CONFIG ----------------
ROM_URL="$1"
[ -z "$ROM_URL" ] && { echo "❌ ROM URL missing"; exit 1; }

WORKDIR="$PWD/work"
TOOLS="$WORKDIR/tools"
OUT="$WORKDIR/out"
MNT="$WORKDIR/mnt"
IMAGES="$WORKDIR/images"
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
mkdir -p "$WORKDIR" "$TOOLS" "$OUT" "$MNT" "$IMAGES"
export PATH="$TOOLS:$PATH"

echo "🛠 Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y \
  erofs-utils \
  jq \
  zip \
  unzip \
  aria2 \
  python3 \
  openjdk-17-jdk \
  aapt \
  apksigner \
  android-sdk-libsparse-utils \
  fuse

# ---------------- TOOLS ----------------
if ! command -v payload-dumper-go &>/dev/null; then
  echo "⬇️ Installing payload-dumper-go"
  curl -L https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz | tar xz
  mv payload-dumper-go "$TOOLS/"
  chmod +x "$TOOLS/payload-dumper-go"
fi

# ---------------- DOWNLOAD ROM ----------------
cd "$WORKDIR"
echo "⬇️ Downloading ROM..."
aria2c -x16 -o rom.zip "$ROM_URL"

unzip -q rom.zip payload.bin
rm rom.zip

echo "📦 Extracting payload..."
payload-dumper-go -o "$IMAGES" payload.bin
rm payload.bin

# ---------------- EXTRACT PARTITIONS ----------------
for p in "${PARTS[@]}"; do
  IMG="$IMAGES/$p.img"
  [ ! -f "$IMG" ] && continue

  echo "🔓 Extracting $p"
  mkdir -p "$WORKDIR/$p"

  sudo erofsfuse "$IMG" "$MNT"
  sudo cp -a "$MNT/." "$WORKDIR/$p/"
  sudo fusermount -u "$MNT"
  sudo chown -R "$(whoami):$(whoami)" "$WORKDIR/$p"

  rm "$IMG"
done

# ---------------- SAFE DEBLOAT ----------------
echo "🗑 Safe debloating..."
for path in "${DEBLOAT_PATHS[@]}"; do
  for p in "${PARTS[@]}"; do
    TARGET="$WORKDIR/$p/$path"
    [ -d "$TARGET" ] && rm -rf "$TARGET"
  done
done

# ---------------- GApps INSTALL ----------------
echo "📲 Installing GApps..."

mkdir -p "$WORKDIR/product/etc/permissions"

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

cp "$GAPPS_DIR/permissions"/*.xml "$WORKDIR/product/etc/permissions/"

# ---------------- SIGN PRIV-APPS ----------------
echo "🔐 Signing priv-apps..."
for apk in $(find "$WORKDIR/product/priv-app" -name "*.apk"); do
  tmp="${apk}.signed"
  apksigner sign \
    --key "$KEYS/platform.pk8" \
    --cert "$KEYS/platform.x509.pem" \
    --out "$tmp" \
    "$apk"
  mv "$tmp" "$apk"
  chmod 644 "$apk"
done

# ---------------- PROPERTIES ----------------
cat >> "$WORKDIR/product/etc/build.prop" <<EOF
ro.miui.has_gmscore=1
persist.sys.gms.enabled=1
EOF

# ---------------- REPACK EROFS ----------------
echo "📦 Repacking partitions..."
for p in "${PARTS[@]}"; do
  [ ! -d "$WORKDIR/$p" ] && continue
  mkfs.erofs "$OUT/$p.img" "$WORKDIR/$p"
done

# ---------------- BUILD SUPER ----------------
echo "🧩 Building super.img..."
SUPER_SIZE=$(du -sb "$OUT"/*.img | awk '{s+=$1} END {print int(s*1.15)}')

LP_ARGS=()
for p in "${PARTS[@]}"; do
  [ -f "$OUT/$p.img" ] || continue
  LP_ARGS+=(--partition "$p:readonly:0:super" --image "$p=$OUT/$p.img")
done

lpmake \
  --metadata-size 65536 \
  --super-name super \
  --device super:$SUPER_SIZE \
  "${LP_ARGS[@]}" \
  --output "$OUT/super.img"

# ---------------- OUTPUT ----------------
cd "$OUT"
zip -q Firmware.zip super.img

echo "✅ BUILD COMPLETE – Firmware.zip READY"
