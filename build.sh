#!/bin/sh
set -eux

# Some assumption made:
# - The default username of clearlinux is clear and it will be created by default and has sudo permission without password
# - However, default clearlinux does not provide proper pam configurations under /usr/share/pam.d/ which makes login to the VM not possible
# - We provide these files in openstack/content and a file list will be created and the ucd will be notified through meta_data.json, which then put those files to correct location
# - The default clearlinux qcow2 image is full.
# - We will resize the disk image, fix the GPT table, resize the partition and grow the filesystem to 32G
# - Cloudhypervisor still does not support qcow2 backing file, although the claim supporting code is merged since v34
# - We will create a full sized image instead

self=$(readlink -f $0)
self=$(dirname "$self")
cd "$self"

_clean_up() {
  set +e
  sudo qemu-nbd --disconnect /dev/nbd0
  sleep 3
  sudo rmmod nbd
  # qemu-img info --backing-chain root.img
}
clean_up() {
  _clean_up &> /dev/null
}
trap clean_up EXIT

version=42020
pubkey=$'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP8lyVDmMwXauShyBZXBH5gXY6FpG2+UsAuAkHko0ALq\n'
cloud_hypervisor="./cloud-hypervisor"
kernel="vmlinux"

variant=cloudguest
image_url=https://cdn-alt.download.clearlinux.org/releases/${version}/clear/clear-${version}-${variant}.img.xz
compressed_image=$(basename ${image_url})
image=$(basename ${image_url} .xz)
hostname=clr
uuid=$(uuidgen)

tap=ichb4
ip=192.168.92.104
mac=2e:89:a8:e4:92:04

ssh() { command ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null clear@$ip "$@"; }

echo === downloading base clear image
until curl -fsSL ${image_url}-SHA512SUMS | sha512sum -c; do
  wget -O ${compressed_image} ${image_url}
done
xz -dfk ${compressed_image}


echo === creating rootfs
# backing is not supported, revert back to flattened image
# qemu-img create -f qcow2 -b ${image} -F qcow2 -o compression_type=zstd root.img 32G
qemu-img convert -O qcow2 -o compression_type=zstd ${image} root.img
qemu-img resize root.img 32G


echo === fixing disk size
sudo modprobe nbd max_part=1
sudo qemu-nbd --connect=/dev/nbd0 root.img
# wait for nbd to be ready
sleep 3
sudo fdisk -l /dev/nbd0
sudo sgdisk -e /dev/nbd0
sudo parted /dev/nbd0 resizepart 2 100%
sudo e2fsck -p -f /dev/nbd0p2
sudo resize2fs /dev/nbd0p2
sudo fsck -p /dev/nbd0p2
sudo fdisk -l /dev/nbd0
sudo qemu-nbd --disconnect /dev/nbd0
sudo rmmod nbd || true


echo === preparing cloudinit
content="$self/content"
pushd openstack/content
fd --type file \
  --strip-cwd-prefix \
  -x printf '{ "content_path": "/content/%s", "path": "/%s" }\n' {} {} \
  > "$content" 
popd

metadata="$self/openstack/latest/meta_data.json"
cat "$content" | jq --slurp \
  --arg hostname "$hostname" \
  --arg uuid "$uuid" \
  --arg pubkey "$pubkey" \
  '{ hostname: $hostname, uuid: $uuid, public_keys: { userkey: $pubkey }, files: . }' \
  > "$metadata"

userdata="$self/openstack/latest/user_data"
cat > "$userdata" <<EOF
#cloud-config
package_upgrade: false
packages: [bcc, bpftrace, gdb, llvm, htop, man-pages, neovim, net-tools, network-basic, parallel, parted, patch, performance-tools, redis-native, rsync, storage-utils, sysadmin-basic, tmux, tree, unzip, wget, which, xz, zstd, ncdu, lsof, lz4, linux-tools]
service:
- start:
  - NetworkManager
EOF

rm -f cloudinit
mkdosfs -n config-2 -C cloudinit 8192
mcopy -o -i cloudinit -s openstack ::


echo === booting and applying cloudinit config
cmdline="console=ttyS0 console=hvc0 root=/dev/vda2 rw rootfstype=ext4,f2fs quiet loglevel=8 ignore_loglevel"

"${cloud_hypervisor}" \
  --cmdline "${cmdline}" \
  --kernel "${kernel}" \
  --disk path=root.img \
         path=cloudinit \
  --cpus boot=2 \
  --memory size=4G \
  --net tap=$tap,mac=$mac \
  --serial tty \
  --console off \
  1> stdout 2>stderr &
vm_pid=$!
# wait for boot
sleep 30

# wait swupd to install all packages
until [ "starting" != "$(ssh systemctl is-system-running)" ]; do
  sleep 30;
done
ssh sudo poweroff || true
sleep 3
kill $vm_pid
wait $vm_pid


echo === done
