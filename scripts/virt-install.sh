#!/usr/bin/env bash

set -e

# Base settings
RAM_MB=4096
VCPUS=2
DISK_SIZE=30
POOL_PATH="/var/lib/libvirt/images"
OS_VARIANT="generic"
BRIDGE="br0"
ISO="/var/lib/libvirt/images/debian-13.5.0-amd64-auto.iso"

# VM names
VMS=(
    k8s-mstr00
    k8s-node00
    k8s-node01
    k8s-node02
)

create_vms() {
    for VM in "${VMS[@]}"; do
        echo "Creating VM: $VM"

        sudo virt-install \
            --name "$VM" \
            --memory ${RAM_MB} \
            --vcpus ${VCPUS} \
            --cpu host-passthrough \
            --machine q35 \
            --controller type=scsi,model=virtio-scsi \
            --disk "path=${POOL_PATH}/${VM}.qcow2,size=${DISK_SIZE},format=qcow2,bus=scsi,cache=none,io=native,discard=unmap" \
            --network bridge=${BRIDGE},model=virtio \
            --graphics spice \
            --video virtio \
            --os-variant ${OS_VARIANT} \
            --console pty,target_type=serial \
            --cdrom "${ISO}" \
            --boot useserial=on \
            --noautoconsole \
            --noreboot

    done

    echo "✅ All VMs created."
}

delete_vms() {
    for VM in "${VMS[@]}"; do
        echo "Deleting VM: $VM"

        # Destroy if running
        if sudo virsh dominfo "$VM" &>/dev/null; then
            sudo virsh destroy "$VM" &>/dev/null || true

            # Undefine and remove storage
            sudo virsh undefine "$VM" --remove-all-storage
            echo "✅ $VM removed"
        else
            echo "⚠️ $VM not found, skipping"
        fi
    done

    echo "✅ Cleanup complete."
}

# -------- CLI handling --------

case "$1" in
    -c | --create)
        create_vms
        ;;
    -d | --delete)
        delete_vms
        ;;
    *)
        echo "Usage: $0 {-c|--create | -d|--delete}"
        exit 1
        ;;
esac
