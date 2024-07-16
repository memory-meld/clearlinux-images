#!/bin/bash
set -eux

self="$(dirname "$(readlink -f "$0")")"
cd "$self"

version=42030
variant=cloudguest
image_url=https://cdn-alt.download.clearlinux.org/releases/${version}/clear/clear-${version}-${variant}.img.xz
config_url=https://cdn-alt.download.clearlinux.org/releases/${version}/clear/config/image/${variant}.yaml
compressed_image=$(basename ${image_url})
image=$(basename ${image_url} .xz)

hostname=clr
uuid=$(uuidgen)
pubkey=$'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP8lyVDmMwXauShyBZXBH5gXY6FpG2+UsAuAkHko0ALq\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINI0chGIKX8+R4oyO44rzLlAO+WBjzN5iJcQHp5pUtk3\n'
metadata="$self/openstack/latest/meta_data.json"
userdata="$self/openstack/latest/user_data"

kernel="vmlinux.bin"
cmdline="console=ttyS0 console=hvc0 root=/dev/vda2 rw rootfstype=ext4,f2fs quiet loglevel=8 ignore_loglevel"

ip=192.168.232.200
subnet=192.168.232
mac=2e:89:a8:e4:e8:64
tap=clrimg100
virbr=virbr-${tap}

chmod 600 id_ed25519
sudo chmod a+rw /dev/kvm


ssh() { command ssh -i id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null clear@$ip "$@"; }
clean_up() {
  set +e
  sudo ip tuntap del $tap mode tap
  sudo virsh net-destroy $virbr
  sudo virsh net-undefine $virbr
}
trap "trap - SIGTERM; clean_up" SIGINT SIGTERM EXIT



echo "=== downloading base clear image"
until curl -fsSL ${image_url}-SHA512SUMS | sha512sum -c; do
  wget --progress=dot:giga -O ${compressed_image} ${image_url}
done
xz -dfk ${compressed_image}



echo "=== creating rootfs"
qemu-img convert -O qcow2 -o compression_type=zstd ${image} root.img
# cloudinit will resize the fs on first boot
qemu-img resize root.img 32G



echo "=== generating cloudinit data"
mkdir -p openstack/{content,latest}
# https://github.com/clearlinux/micro-config-drive/blob/c4b7f9161add40efd39e70832d3cfaac6e70b78a/src/datasources/openstack.c#L108
fd --base-directory openstack/content \
    --type file \
  | xq --raw-input \
    '{ content_path: ("/content/" + .), path: ("/" + .) }' \
  | xq --slurp \
    --arg hostname "$hostname" \
    --arg uuid "$uuid" \
    --arg pubkey "$pubkey" \
    '{ hostname: $hostname, uuid: $uuid, public_keys: { userkey: $pubkey }, files: . }' \
  | tee "$metadata"
# It seems that the ucd will sequentially traverse the nodes in the yaml
# https://github.com/clearlinux/micro-config-drive/blob/c4b7f9161add40efd39e70832d3cfaac6e70b78a/src/interpreters/cloud_config.c#L249C13-L249C33
tee "$userdata" <<EOF
#cloud-config
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
fbootcmd:
- pip install --upgrade --user drgn fire;
- usermod -s /usr/bin/fish clear;
EOF



echo "=== creating cloudinit image"
rm -f cloudinit
mkdosfs -n config-2 -C cloudinit 8192
mcopy -o -i cloudinit -s openstack ::



echo "=== creating NAT netowrk and network bridge"
tee network.xml <<EOF
<network>
  <name>${virbr}</name>
  <bridge name='${virbr}'/>
  <forward/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${subnet}.2' end='${subnet}.254'/>
      <host mac='${mac}' ip='${ip}'/>
    </dhcp>
  </ip>
</network>
EOF
sudo virsh net-define network.xml
sudo virsh net-start $virbr
sudo ip tuntap del $tap mode tap
sudo ip tuntap add $tap mode tap
sudo brctl addif $virbr $tap
sudo ip link set dev $tap up



echo "=== booting and applying cloudinit config"
cloud-hypervisor \
  --cmdline "${cmdline}" \
  --kernel "${kernel}" \
  --disk path=root.img \
         path=cloudinit \
  --cpus boot=4 \
  --memory size=12G \
  --net tap=$tap,mac=$mac \
  --serial tty \
  --console off \
  1> stdout 2>stderr &
vm_pid=$!
# wait for boot
sleep 60



echo "=== waiting for swupd to install all packages"
status=$(ssh systemctl is-system-running --wait)
if [ "$status" != "running" ] && [ "$status" != "degraded" ]; then
  echo "=== failed: guest systemctl status: $status"
  exit 1
fi



echo "=== shutting down VM"
ssh sudo journalctl | tee journalctl.log
ssh sudo poweroff || true
kill $vm_pid || true
wait $vm_pid || true



echo "=== done"
