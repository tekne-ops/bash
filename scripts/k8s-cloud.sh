#!/usr/bin/env bash
set -e

POOL_PATH="/var/lib/libvirt/images"
BASE_IMAGE="${POOL_PATH}/debian-13-generic-amd64.qcow2"

VMS=(
    k8s-mstr00
    k8s-node00
    k8s-node01
    k8s-node02
)

declare -A IPS=(
    ["k8s-mstr00"]="192.168.122.216"
    ["k8s-node00"]="192.168.122.139"
    ["k8s-node01"]="192.168.122.62"
    ["k8s-node02"]="192.168.122.26"
)

SSH_KEY_DVALIENTE="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCnLP7QGTEj9VRAJyls0JnkDeanaQuDk3o//hPR17wREgrNDSk1g326I+hwS+nElV4z1g9s+EyyRfBMh2jp8wMoFMwoqhJhHLc77NTb6eaxHji/CJuwMM5nRTYPEUIm0iyusT37kh04i4fS7sWFJNmR7eJqHckfocsXRSra4lq/MIDTVtardZDAK9mrZZSIm9xPqNpSzv4O0bBgrjL7hwLxmK6CpggSWrLqXRVykAe0eDj52uFSl74wF4YX6nTfffvqy7xnJwnzQg29RlIO8xcQeVbpALoxhWWMmhhpntHVSmIF3+a3/wmlm9eHWIUq2jIvEnInu430oo3+Zr0gsPULdw14SkTKo8wNelNW6HFxqlVSAJ0uk+aajU3TJwse+3jJCFlg80ib5260rPPf6mv9p14jp+kcWRCpeRK58oHBeix6qgczzjRo292wQvRTWpp2dlfS9vjqcDuYAzH6HZW3kxo4uHE38JiO8BsF57TrAqAZbaZkXZVp+fg30Z6DjnGAnjbuckXX7iP7O86hGwRQ72aZn/4ctmnJjQmAdOC6REKuAAs42eOim2RuN5hBkEdzzB7peVHUfEgA36dGfIu/aGVEt3ZO94+WItVRIW8tBCCgyMi9wFd7YXRfLP8EfvSGcJgs8wF/5I8Nw9yI7HX4i48rabBcdjIWB7xREzfr2w== fierce_brake@yugen.tekne.sv"
SSH_KEY_DEVOPS="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCorr9oh2s4scmIpotsGaH0D4VpY7kjCknrU+cefo1zbHt5LkiyK1wc/v/n/ct5Fk1Oeb8LIMtiqH5mvl21lVGAVx80ui8+aYPit1K40fbk2nFu6pqlCWGWr+QrFu8cU7S/DZCWJd2MMGPJEah31Sd2KQVC299/lTTAY1BnlFo5nbmmxP2TUnl8BixiH7vweQtKCt7FlmA1GGwTbR6zond0Pan0n/AiVaeaDQF9x/MAUS1MCEWRew6kI8YsF7RLk/8LrxfeBU4BqeiQnUHd+fy4fise+9gk9sC2LGacR4ZAQZ3M6kKc+chZdrwCiWH4wIYUpxTFZp09TMdm61xoNx95"
# shellcheck disable=SC2016
PASSWD_HASH='$6$lSMSEmWfXjbU7zpu$7X8k4zz836AAyPLbR2eOxY.IzRRepwnf3zkn88e72JyeAYFGiZ2J/RxwgjDU3azYkodNfOy0Klr1fz8lezOqj.'

create_vm() {
    VM=$1

    echo "Creating $VM..."

    # disk
    sudo qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMAGE}" "${POOL_PATH}/${VM}.qcow2" 30G

    # cloud-init files
    mkdir -p "/tmp/${VM}"

    cat >"/tmp/${VM}/user-data" <<EOF
#cloud-config
hostname: ${VM}

users:
  - name: dvaliente
    passwd: ${PASSWD_HASH}
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_KEY_DVALIENTE}
    sudo: ALL=(ALL:ALL) ALL
    groups: sudo
    shell: /bin/bash
  - name: devops
    passwd: ${PASSWD_HASH}
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_KEY_DEVOPS}
    sudo: ALL=(ALL:ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash

ssh_pwauth: false

network:
  config: disabled

write_files:
  - path: /etc/netplan/01-static.yaml
    content: |
      network:
        version: 2
        ethernets:
          enp1s0:
            dhcp4: false
            addresses:
              - ${IPS[$VM]}/24
            routes:
              - to: default
                via: 192.168.122.1
            nameservers:
              addresses: [8.8.8.8, 1.1.1.1]

runcmd:
  - netplan apply

package_update: true
packages:
  - qemu-guest-agent
EOF

    cat >"/tmp/${VM}/meta-data" <<EOF
instance-id: ${VM}
local-hostname: ${VM}
EOF

    sudo genisoimage -output "${POOL_PATH}/${VM}-seed.iso" \
        -volid cidata -joliet -rock \
        "/tmp/${VM}/user-data" "/tmp/${VM}/meta-data"

    sudo virt-install \
        --name "${VM}" \
        --memory 2048 \
        --vcpus 2 \
        --cpu host-passthrough \
        --machine q35 \
        --controller type=scsi,model=virtio-scsi \
        --osinfo debian13 \
        --disk "path=${POOL_PATH}/${VM}.qcow2,format=qcow2,bus=scsi,cache=none,io=native,discard=unmap" \
        --disk "path=${POOL_PATH}/${VM}-seed.iso,device=cdrom" \
        --network network=default,model=virtio \
        --video virtio \
        --graphics spice \
        --console pty,target_type=serial \
        --import \
        --wait 0

}

delete_vm() {
    VM=$1
    sudo virsh destroy "$VM" &>/dev/null || true
    sudo virsh undefine "$VM" --remove-all-storage --nvram || true
}

case "$1" in
    -c)
        for vm in "${VMS[@]}"; do
            create_vm "$vm"
        done
        ;;
    -d)
        for vm in "${VMS[@]}"; do
            delete_vm "$vm"
        done
        ;;
    *)
        echo "Usage: $0 -c | -d"
        ;;
esac
