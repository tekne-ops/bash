#!/bin/bash
set -e

ISO_SRC="$HOME/Downloads/Win11_25H2_English_x64_v2.iso"
WORKDIR="$HOME/Downloads/winiso"
OUTISO="$HOME/Downloads/Win11_25H2_x64_v2.iso"

sudo pacman -S --needed --noconfirm xorriso p7zip

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

7z x "$ISO_SRC" -o"$WORKDIR"

cat > "$WORKDIR/sources/ei.cfg" <<EOF
[EditionID]
[Channel]
Retail
[VL]
0
EOF

xorriso -as mkisofs \
  -iso-level 3 \
  -o "$OUTISO" \
  -full-iso9660-filenames \
  -volid "WIN11_PRO" \
  -eltorito-boot boot/etfsboot.com \
  -eltorito-catalog boot/boot.cat \
  -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys.bin \
  -no-emul-boot \
  "$WORKDIR"

echo "✅ ISO created: $OUTISO"
