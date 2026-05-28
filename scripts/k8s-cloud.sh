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
  [k8s-mstr00]="192.168.122.216"
  [k8s-node00]="192.168.122.139"
  [k8s-node01]="192.168.122.62"
  [k8s-node02]="192.168.122.26"
)

SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"

create_vm() {
  VM=$1

  echo "Creating $VM..."

  # disk
  sudo qemu-img create -f qcow2 -F qcow2 -b ${BASE_IMAGE} ${POOL_PATH}/${VM}.qcow2 30G

  # cloud-init files
  mkdir -p /tmp/${VM}

  cat > /tmp/${VM}/user-data <<EOF
#cloud-config
hostname: ${VM}

users:
  - name: debian
    ssh_authorized_keys:
      - ${SSH_KEY}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash

ssh_pwauth: false

# 🔴 Disable default networking completely
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

  cat > /tmp/${VM}/meta-data <<EOF
instance-id: ${VM}
local-hostname: ${VM}
EOF

  sudo genisoimage -output ${POOL_PATH}/${VM}-seed.iso \
    -volid cidata -joliet -rock \
    /tmp/${VM}/user-data /tmp/${VM}/meta-data

sudo virt-install \
  --name ${VM} \
  --memory 4096 \
  --vcpus 2 \
  --cpu host-passthrough \
  --machine q35 \
  --controller type=scsi,model=virtio-scsi \
  --osinfo debian13 \
  --disk path=${POOL_PATH}/${VM}.qcow2,format=qcow2,bus=scsi,cache=none,io=native,discard=unmap \
  --disk path=${POOL_PATH}/${VM}-seed.iso,device=cdrom \
  --network network=default,model=virtio \
  --video virtio \
  --graphics spice \
  --console pty,target_type=serial \
  --import \
  --wait 0

}

delete_vm() {
  VM=$1
  sudo virsh destroy $VM &>/dev/null || true
  sudo virsh undefine $VM --remove-all-storage || true
}

case "$1" in
  -c)
    for vm in "${VMS[@]}"; do
      create_vm $vm
    done
    ;;
  -d)
    for vm in "${VMS[@]}"; do
      delete_vm $vm
    done
    ;;
  *)
    echo "Usage: $0 -c | -d"
    ;;
esac
