#!/bin/bash
set -eux

# required utils: ssh wget curl qemi-img fd jq xz mkdosfs mcopy uuidgen

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

version=42030
pubkey=$'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP8lyVDmMwXauShyBZXBH5gXY6FpG2+UsAuAkHko0ALq\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINI0chGIKX8+R4oyO44rzLlAO+WBjzN5iJcQHp5pUtk3\n'
cloud_hypervisor="./cloud-hypervisor"
kernel="vmlinux"

variant=cloudguest
image_url=https://cdn-alt.download.clearlinux.org/releases/${version}/clear/clear-${version}-${variant}.img.xz
config_url=https://cdn-alt.download.clearlinux.org/releases/${version}/clear/config/image/${variant}.yaml
compressed_image=$(basename ${image_url})
image=$(basename ${image_url} .xz)
hostname=clr
uuid=$(uuidgen)

tap=ichb100
ip=192.168.92.200
mac=2e:89:a8:e4:92:64

chmod 600 id_ed25519
ssh() { command ssh -i id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null clear@$ip "$@"; }



echo "=== downloading base clear image"
until curl -fsSL ${image_url}-SHA512SUMS | sha512sum -c; do
  wget -O ${compressed_image} ${image_url}
done
xz -dfk ${compressed_image}



echo "=== creating rootfs"
# backing is not supported, revert back to flattened image
# qemu-img create -f qcow2 -b ${image} -F qcow2 -o compression_type=zstd root.img 32G
qemu-img convert -O qcow2 -o compression_type=zstd ${image} root.img
qemu-img resize root.img 32G



echo "=== resizing filesystem"
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



echo "=== generating cloudinit data"
content="$self/content"
pushd openstack/content
fd --type file \
  --strip-cwd-prefix \
  -x printf '{ "content_path": "/content/%s", "path": "/%s" }\n' {} {} \
  > "$content" 
popd

# https://github.com/clearlinux/micro-config-drive/blob/c4b7f9161add40efd39e70832d3cfaac6e70b78a/src/datasources/openstack.c#L108
metadata="$self/openstack/latest/meta_data.json"
cat "$content" | jq --slurp \
  --arg hostname "$hostname" \
  --arg uuid "$uuid" \
  --arg pubkey "$pubkey" \
  '{ hostname: $hostname, uuid: $uuid, public_keys: { userkey: $pubkey }, files: . }' \
  > "$metadata"

# It seems that the ucd will sequentially traverse the nodes in the yaml
# https://github.com/clearlinux/micro-config-drive/blob/c4b7f9161add40efd39e70832d3cfaac6e70b78a/src/interpreters/cloud_config.c#L249C13-L249C33
userdata="$self/openstack/latest/user_data"
cat > "$userdata" <<EOF
#cloud-config
bootcmd:
- pip install --upgrade --user drgn fire
- usermod -s /usr/bin/fish clear
package_upgrade: false
packages:
- shells
- dev-utils
- storage-utils
- network-basic
- sysadmin-basic
- performance-tools
- python-data-science
- neovim
- redis-native
- ncdu
EOF



echo "=== creating cloudinit image"
rm -f cloudinit
mkdosfs -n config-2 -C cloudinit 8192
mcopy -o -i cloudinit -s openstack ::



echo "=== booting and applying cloudinit config"
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



echo "=== waiting for swupd to install all packages"
until [ "starting" != "$(ssh systemctl is-system-running)" ]; do
  sleep 30;
done



# echo "=== install additional packages"
# ssh sudo pip install --upgrade --user drgn fire



echo "=== shutting down VM"
ssh sudo journalctl | tee journalctl.log
ssh sudo poweroff || true
sleep 3
kill $vm_pid || true
wait $vm_pid || true



echo "=== done"
