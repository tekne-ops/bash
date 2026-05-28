#!/usr/bin/env bash
set -e

POOL_PATH="/var/lib/libvirt/images"
BASE_IMAGE="${POOL_PATH}/Arch-Linux-x86_64-basic.qcow2"

VMS=(
  arch-00
)

SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"

create_vm() {
  VM=$1

  echo "Creating $VM..."

  # disk
  sudo qemu-img create -f qcow2 -F qcow2 -b ${BASE_IMAGE} ${POOL_PATH}/${VM}.qcow2 40G

  # cloud-init files
  mkdir -p /tmp/${VM}

  cat > /tmp/${VM}/user-data <<EOF
#cloud-config
hostname: ${VM}

# users:
  # - name: debian
    # ssh_authorized_keys:
      # - ${SSH_KEY}
    # sudo: ALL=(ALL) NOPASSWD:ALL
    # groups: sudo
    # shell: /bin/bash

# ssh_pwauth: true

# chpasswd:
  # list: |
    # debian:debian
  # expire: false

# network:
  # version: 2
  # ethernets:
    # enp1s0:
      d# hcp4: true

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


print_ips() {
  echo ""
  echo "========== VM IP ADDRESSES =========="

  for VM in "${VMS[@]}"; do
    printf "%-15s : " "$VM"

    # Try multiple times (VM may need a few seconds)
    for i in {1..10}; do
      IP=$(sudo virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1)

      if [[ -n "$IP" ]]; then
        echo "$IP"
        break
      fi

      sleep 2
    done

    # If still no IP
    if [[ -z "$IP" ]]; then
      echo "⚠️ not available"
    fi
  done

  echo "===================================="
}

case "$1" in
  -c)
    for vm in "${VMS[@]}"; do
      create_vm $vm
    done

    echo "⏳ Waiting for VMs to obtain IP addresses..."
    sleep 10
    print_ips
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
