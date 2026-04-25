#!/bin/bash

sudo pacman -S --needed xorriso p7zip


mkdir /home/dvaliente/Downloads/winiso
7z x /home/dvaliente/Downloads/Win11_25H2_English_x64_v2.iso -o/home/dvaliente/Downloads/winiso


cat > /home/dvaliente/Downloads/winiso/sources/ei.cfg <<EOF
[EditionID]
[Channel]
Retail
[VL]
0
EOF


xorriso -as mkisofs \
  -iso-level 3 \
  -o Win10_Pro_auto.iso \
  -full-iso9660-filenames \
  -volid "Win10_Pro" \
  -eltorito-boot boot/etfsboot.com \
  -eltorito-catalog boot/boot.cat \
  -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys.bin \
  -no-emul-boot \
  /home/dvaliente/Downloads/winiso
