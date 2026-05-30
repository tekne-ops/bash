#!/bin/bash
# customize.sh - Apply tekne customizations to arch-boxes
#
# Modifies the arch-boxes build to:
#   - Install a custom package set (linux-tkg-themis kernel + tooling)
#   - Create dvaliente and devops users with SSH keys and sudoers
#   - Add a custom pacman repository for non-standard packages
#
# Non-standard packages that require a custom repo:
#   linux-tkg-themis, linux-tkg-themis-headers, blesh-git, pikaur,
#   schedtoold, ttf-ms-win10-auto, python311
#
# Usage (from /srv/code/tekne/bash/scripts/):
#   1. Run: ./customize.sh
#   2. Build: sudo /srv/code/tekne/arch-boxes/build.sh [BUILD_VERSION]
#
# Safe to re-run (idempotent).

set -euo pipefail

ARCH_BOXES="/srv/code/tekne/arch-boxes"
ARCH_BOXES_REPO="https://gitlab.archlinux.org/archlinux/arch-boxes.git"
CUSTOM_REPO_URL="http://repo.tekne.sv"

# --- Clone arch-boxes if not present, pull if already cloned ---
if [[ ! -d "$ARCH_BOXES/.git" ]]; then
  echo "==> Cloning arch-boxes into $ARCH_BOXES..."
  git clone "$ARCH_BOXES_REPO" "$ARCH_BOXES"
else
  echo "==> Updating existing arch-boxes checkout..."
  git -C "$ARCH_BOXES" pull --ff-only
fi

sudo pacman -Sy --needed --noconfirm gptfdisk btrfs-progs

echo "==> Applying tekne customizations to arch-boxes..."

# --- Backup originals (only on first run) ---
for f in build.sh images/basic.sh; do
  if [[ ! -f "$ARCH_BOXES/$f.orig" ]]; then
    cp "$ARCH_BOXES/$f" "$ARCH_BOXES/$f.orig"
    echo "  Backed up $f -> $f.orig"
  fi
done

# --- Patch build.sh ---
echo "  Patching build.sh (disk size, packages, kernel preset, custom repo)..."

sed -i 's/readonly DEFAULT_DISK_SIZE="[^"]*"/readonly DEFAULT_DISK_SIZE="10G"/' "$ARCH_BOXES/build.sh"

awk -v repo="$CUSTOM_REPO_URL" '
BEGIN { tekne_found = 0; multilib_found = 0 }

/pacstrap -c -C pacman.conf -K -M/ {
  print "  pacstrap -c -C pacman.conf -K -M \"${MOUNT}\" \\"
  print "    base base-devel intel-ucode linux-tkg-themis linux-tkg-themis-headers \\"
  print "    linux-firmware linux-firmware-broadcom linux-firmware-liquidio \\"
  print "    linux-firmware-mellanox linux-firmware-nfp linux-firmware-qlogic \\"
  print "    grub openssh sudo btrfs-progs dosfstools efibootmgr qemu-guest-agent \\"
  print "    f2fs-tools exfatprogs exfat-utils \\"
  print "    python311 python-pip python-pipx python-passlib python-pipenv \\"
  print "    ansible-core ansible-lint ansible \\"
  print "    blesh-git pikaur schedtoold \\"
  print "    vim vim-tagbar vim-tabular vim-syntastic vim-supertab vim-spell-es vim-spell-en \\"
  print "    vim-nerdtree vim-nerdcommenter vim-devicons vim-ansible \\"
  print "    mlocate bash-completion pkgfile acpi acpid iwd wpa_supplicant \\"
  print "    wireless-regdb rsync git wget reflector iptables-nft less usb_modeswitch \\"
  print "    libsecret gzip tar zlib xz nvme-cli openssl screen gnupg bind \\"
  print "    cronie inetutils whois zip unzip p7zip sed fuse mdadm jq curl make pkg-config \\"
  print "    dbus openbsd-netcat irqbalance schedtool shfmt gsmartcontrol shellcheck bats \\"
  print "    cpupower devtools fakechroot fakeroot tcpdump parted xfsprogs libsmbios fwupd \\"
  print "    pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber alsa-utils \\"
  print "    wmctrl man udisks2 restic noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation \\"
  print "    ttf-ms-win10-auto"
  # Skip current line and any continuation lines (backslash-terminated)
  while (/\\[ \t]*$/) {
    if (getline <= 0) break
  }
  next
}

/mkinitcpio -p linux -- -S autodetect/ {
  sub(/-p linux -- /, "-p linux-tkg-themis -- ")
  print
  next
}

/^\[tekne\]$/ { tekne_found = 1 }
/^\[multilib\]$/ { multilib_found = 1 }

/cat <<.*EOF.*>.*pacman.conf/ { in_pacman_conf = 1 }

/^EOF$/ && in_pacman_conf {
  if (!multilib_found) {
    print ""
    print "[multilib]"
    print "Include = /etc/pacman.d/mirrorlist"
  }
  in_pacman_conf = 0
}

/^\[extra\]$/ {
  if (!tekne_found) {
    print "[tekne]"
    print "SigLevel = Optional TrustAll"
    print "Server = " repo
    print ""
  }
  print $0
  next
}

{ print }
' "$ARCH_BOXES/build.sh" > "$ARCH_BOXES/build.sh.tmp"
mv "$ARCH_BOXES/build.sh.tmp" "$ARCH_BOXES/build.sh"
chmod +x "$ARCH_BOXES/build.sh"

# Prevent $arch expansion in the pacman.conf heredoc (idempotent)
sed -i "s/cat <<EOF >pacman.conf/cat <<'EOF' >pacman.conf/" "$ARCH_BOXES/build.sh"

# --- Rewrite images/basic.sh ---
echo "  Writing images/basic.sh (users, sudoers, SSH keys)..."

cat > "$ARCH_BOXES/images/basic.sh" << 'BASICEOF'
#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="Arch-Linux-x86_64-basic-${build_version}.qcow2"
DISK_SIZE="40G"
PACKAGES=()
SERVICES=()

function pre() {
  # --- Users ---
  arch-chroot "${MOUNT}" /usr/bin/useradd -m -U -p '$6$lSMSEmWfXjbU7zpu$7X8k4zz836AAyPLbR2eOxY.IzRRepwnf3zkn88e72JyeAYFGiZ2J/RxwgjDU3azYkodNfOy0Klr1fz8lezOqj.' dvaliente
  arch-chroot "${MOUNT}" /usr/bin/useradd -m -U -p '$6$lSMSEmWfXjbU7zpu$7X8k4zz836AAyPLbR2eOxY.IzRRepwnf3zkn88e72JyeAYFGiZ2J/RxwgjDU3azYkodNfOy0Klr1fz8lezOqj.' devops

  # --- Sudoers ---
  cat > "${MOUNT}/etc/sudoers.d/dvaliente" << 'SUDOEOF'
dvaliente ALL=(ALL:ALL) ALL
dvaliente ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman,/usr/bin/pikaur,/usr/bin/makepkg,/usr/bin/docker,/usr/bin/fwupdmgr,/usr/local/bin/kubectl
SUDOEOF
  chmod 440 "${MOUNT}/etc/sudoers.d/dvaliente"

  cat > "${MOUNT}/etc/sudoers.d/devops" << 'SUDOEOF'
devops ALL=(ALL:ALL) ALL
devops ALL=(ALL:ALL) NOPASSWD: ALL
SUDOEOF
  chmod 440 "${MOUNT}/etc/sudoers.d/devops"

  # --- SSH authorized keys: dvaliente ---
  install -d -m 700 "${MOUNT}/home/dvaliente/.ssh"
  cat > "${MOUNT}/home/dvaliente/.ssh/authorized_keys" << 'SSHEOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCnLP7QGTEj9VRAJyls0JnkDeanaQuDk3o//hPR17wREgrNDSk1g326I+hwS+nElV4z1g9s+EyyRfBMh2jp8wMoFMwoqhJhHLc77NTb6eaxHji/CJuwMM5nRTYPEUIm0iyusT37kh04i4fS7sWFJNmR7eJqHckfocsXRSra4lq/MIDTVtardZDAK9mrZZSIm9xPqNpSzv4O0bBgrjL7hwLxmK6CpggSWrLqXRVykAe0eDj52uFSl74wF4YX6nTfffvqy7xnJwnzQg29RlIO8xcQeVbpALoxhWWMmhhpntHVSmIF3+a3/wmlm9eHWIUq2jIvEnInu430oo3+Zr0gsPULdw14SkTKo8wNelNW6HFxqlVSAJ0uk+aajU3TJwse+3jJCFlg80ib5260rPPf6mv9p14jp+kcWRCpeRK58oHBeix6qgczzjRo292wQvRTWpp2dlfS9vjqcDuYAzH6HZW3kxo4uHE38JiO8BsF57TrAqAZbaZkXZVp+fg30Z6DjnGAnjbuckXX7iP7O86hGwRQ72aZn/4ctmnJjQmAdOC6REKuAAs42eOim2RuN5hBkEdzzB7peVHUfEgA36dGfIu/aGVEt3ZO94+WItVRIW8tBCCgyMi9wFd7YXRfLP8EfvSGcJgs8wF/5I8Nw9yI7HX4i48rabBcdjIWB7xREzfr2w== fierce_brake@yugen.tekne.sv
SSHEOF
  chmod 600 "${MOUNT}/home/dvaliente/.ssh/authorized_keys"
  arch-chroot "${MOUNT}" chown -R dvaliente:dvaliente /home/dvaliente/.ssh

  # --- SSH authorized keys: devops ---
  install -d -m 700 "${MOUNT}/home/devops/.ssh"
  cat > "${MOUNT}/home/devops/.ssh/authorized_keys" << 'SSHEOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCorr9oh2s4scmIpotsGaH0D4VpY7kjCknrU+cefo1zbHt5LkiyK1wc/v/n/ct5Fk1Oeb8LIMtiqH5mvl21lVGAVx80ui8+aYPit1K40fbk2nFu6pqlCWGWr+QrFu8cU7S/DZCWJd2MMGPJEah31Sd2KQVC299/lTTAY1BnlFo5nbmmxP2TUnl8BixiH7vweQtKCt7FlmA1GGwTbR6zond0Pan0n/AiVaeaDQF9x/MAUS1MCEWRew6kI8YsF7RLk/8LrxfeBU4BqeiQnUHd+fy4fise+9gk9sC2LGacR4ZAQZ3M6kKc+chZdrwCiWH4wIYUpxTFZp09TMdm61xoNx95
SSHEOF
  chmod 600 "${MOUNT}/home/devops/.ssh/authorized_keys"
  arch-chroot "${MOUNT}" chown -R devops:devops /home/devops/.ssh

  # --- Network (DHCP on wired interfaces) ---
  cat <<EOF >"${MOUNT}/etc/systemd/network/80-dhcp.network"
[Match]
Name=en*
Name=eth*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
EOF
}

function post() {
  qemu-img convert -c -f raw -O qcow2 "${1}" "${2}"
  rm "${1}"
}
BASICEOF
chmod +x "$ARCH_BOXES/images/basic.sh"

echo ""
echo "==> Done! Changes applied:"
echo "    - build.sh: disk size (10G), package list, mkinitcpio preset (linux-tkg-themis), [tekne] + [multilib] repos"
echo "    - images/basic.sh: dvaliente + devops users, sudoers, SSH keys"
echo ""
echo "    Originals saved as *.orig"
echo ""
echo "Build with: sudo /srv/code/tekne/arch-boxes/build.sh [BUILD_VERSION]"
