#!/usr/bin/env bash
# Build the Moto Z2 Play (albus) Debian rootfs image.
# Kernel modules come from the `mainline` branch artifact:
#   KERNEL_MODULES_ARCHIVE, KERNEL_RELEASE (from kernel-release.txt)
set -euo pipefail

: "${KERNEL_RELEASE:=$(cat "$(dirname "${KERNEL_MODULES_ARCHIVE:?set KERNEL_MODULES_ARCHIVE}")/kernel-release.txt")}"
: "${KERNEL_MODULES_ARCHIVE:?set KERNEL_MODULES_ARCHIVE}"
: "${OUT_DIR:?set OUT_DIR}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/conf/rootfs.conf"
source "$ROOT/conf/device.conf"

DEBIAN_SUITE="${DEBIAN_SUITE:?}"
WORK_DIR="${WORK_DIR:-$ROOT/.work}"
STAGE="$WORK_DIR/rootfs"
KREL="$KERNEL_RELEASE"

test -s "$KERNEL_MODULES_ARCHIVE"
mkdir -p "$WORK_DIR" "$OUT_DIR"
sudo rm -rf "$STAGE"

#------------------------------------------------------------------#

sudo mmdebstrap \
  --architectures=arm64 \
  --variant=minbase \
  --components=main \
  --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
  --aptopt='Apt::Install-Recommends "false"' \
  --include=debian-archive-keyring,systemd-sysv,openssh-server,openssh-client,iproute2,iputils-ping,dnsmasq,ca-certificates,kmod,udev,busybox-static,e2fsprogs,util-linux,procps,less,nano,ethtool,iw,wpasupplicant,wireless-regdb,dbus,network-manager,tzdata \
  "$DEBIAN_SUITE" "$STAGE" "$DEB_MIRROR"

#------------------------------------------------------------------#

# Device overlay: sshd (USB-only open root), USB RNDIS services,
# NetworkManager policy and the albus helper scripts.
sudo cp -a "$ROOT/distros/debian/rootfs/." "$STAGE/"
# Windows authoring can store units with exec bits; systemd configs must be 644.
sudo find "$STAGE/etc/systemd/system" "$STAGE/etc/ssh" "$STAGE/etc/NetworkManager" \
  -type f ! -path '*/bin/*' -exec chmod 0644 {} +
sudo find "$STAGE/usr/local/bin" -type f -exec chmod 0755 {} +
# Install original device firmware as regular files; never mount vendor/modem.
bash "$ROOT/sh/firmware.sh" install "$STAGE"
# One shared RNDIS implementation + albus-specific configuration.
sudo install -D -m 0755 "$ROOT/sh/usb-gadget" "$STAGE/usr/local/sbin/usb-gadget"
sudo install -m 0644 "$ROOT/conf/usb.conf" "$STAGE/etc/usb-gadget.conf"
test -x "$STAGE/usr/local/sbin/usb-gadget"
test -s "$STAGE/etc/usb-gadget.conf"

printf '%s\n' "$DEVICE" | sudo tee "$STAGE/etc/hostname" >/dev/null
sudo tee "$STAGE/etc/hosts" >/dev/null <<HOSTS
127.0.0.1 localhost
127.0.1.1 $DEVICE
::1 localhost ip6-localhost ip6-loopback
HOSTS

sudo tee "$STAGE/etc/fstab" >/dev/null <<FSTAB
PARTLABEL=userdata / ext4 rw,noatime 0 1
FSTAB

# USB-only open root SSH; local root password remains non-empty.
RANDOM_PASSWORD="$(openssl rand -hex 48)"
ROOT_HASH="$(openssl passwd -6 "$RANDOM_PASSWORD")"
sudo sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$STAGE/etc/shadow"
unset RANDOM_PASSWORD ROOT_HASH
# The pam stack and sshd_config ship in the overlay; assert them instead of
# writing a second copy here.
test -s "$STAGE/etc/pam.d/sshd"
test -s "$STAGE/etc/ssh/sshd_config"

sudo ssh-keygen -A -f "$STAGE"

sudo systemctl --root="$STAGE" disable ssh.socket 2>/dev/null || true
sudo systemctl --root="$STAGE" disable dnsmasq.service 2>/dev/null || true
sudo systemctl --root="$STAGE" enable \
  usb-gadget.service usb-dhcp.service albus-resize.service \
  NetworkManager.service dbus.socket
sudo systemctl --root="$STAGE" enable ssh.service
sudo systemctl --root="$STAGE" enable systemd-timesyncd.service 2>/dev/null || true

sudo mkdir -p "$STAGE/var/log/journal"

#------------------------------------------------------------------#

# Kernel modules (the archive stores modules-$KREL/lib/modules/$KREL; the
# old rootfs.sh re-wrapped it — mirror that layout handling here).
sudo tar -xf "$KERNEL_MODULES_ARCHIVE" -C "$WORK_DIR"
test -d "$WORK_DIR/modules-$KREL/lib/modules/$KREL" || \
  test -d "$STAGE/lib/modules/$KREL"
mkdir -p "$STAGE/lib/modules"
if [ -d "$WORK_DIR/modules-$KREL/lib/modules/$KREL" ]; then
  sudo cp -a "$WORK_DIR/modules-$KREL/lib/modules/$KREL" "$STAGE/lib/modules/"
fi
test -d "$STAGE/lib/modules/$KREL"
sudo depmod -b "$STAGE" "$KREL"

#------------------------------------------------------------------#

sudo update-binfmts --enable qemu-aarch64 || true
if [ -x /usr/bin/qemu-aarch64-static ]; then
  sudo install -m 0755 /usr/bin/qemu-aarch64-static "$STAGE/usr/bin/qemu-aarch64-static"
fi

cleanup_mounts() {
  sudo umount -R "$STAGE/dev" 2>/dev/null || true
  sudo umount "$STAGE/proc" 2>/dev/null || true
  sudo umount "$STAGE/sys" 2>/dev/null || true
}
trap cleanup_mounts EXIT

sudo mount --bind /dev "$STAGE/dev"
sudo mount -t proc proc "$STAGE/proc"
sudo mount -t sysfs sysfs "$STAGE/sys"
sudo install -d -m 0755 "$STAGE/run/sshd"
sudo chroot "$STAGE" /usr/sbin/sshd -t

test -L "$STAGE/etc/systemd/system/multi-user.target.wants/NetworkManager.service" || \
  test -L "$STAGE/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service"
test -L "$STAGE/etc/systemd/system/multi-user.target.wants/usb-gadget.service"
test -L "$STAGE/etc/systemd/system/multi-user.target.wants/usb-dhcp.service"
test -L "$STAGE/etc/systemd/system/multi-user.target.wants/ssh.service"
test -L "$STAGE/etc/systemd/system/multi-user.target.wants/albus-resize.service"
test -s "$STAGE/etc/ssh/moduli"
test -s "$STAGE/etc/NetworkManager/NetworkManager.conf"

cleanup_mounts
trap - EXIT
sudo rm -f "$STAGE/usr/bin/qemu-aarch64-static"

#------------------------------------------------------------------#

# Fixed initial ext4 capacity (conf/rootfs.conf). albus-resize grows / on
# userdata at first boot. Refuse to publish an image without safe free space.
USED_MB="$(sudo du -sm "$STAGE" | awk '{print $1}')"
IMAGE_MB="$IMAGE_SIZE_MB"
MIN_FREE_MB="$IMAGE_FREE_MIN_DEBIAN"
echo "albus: staged rootfs ${USED_MB} MiB; target ${IMAGE_MB} MiB; minimum free ${MIN_FREE_MB} MiB"

ROOTFS_IMG="$OUT_DIR/debian-albus.ext4"
truncate -s "${IMAGE_MB}M" "$ROOTFS_IMG"
# Preserve journaling; a realistic inode budget avoids the oversized default table.
sudo mkfs.ext4 -F -m 0 -N 32768 -J size=16 -L debian-albus -U random -d "$STAGE" "$ROOTFS_IMG"
test "$(stat -c %s "$ROOTFS_IMG")" -eq $((IMAGE_MB * 1024 * 1024))
ROOTFS_EXT4_UUID="$(blkid -p -o value -s UUID "$ROOTFS_IMG")"
test -n "$ROOTFS_EXT4_UUID"
sudo e2fsck -fn "$ROOTFS_IMG"
test "$(blkid -p -o value -s LABEL "$ROOTFS_IMG")" = "debian-albus"
FS_STATS="$(sudo tune2fs -l "$ROOTFS_IMG")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || {
  echo "ERROR: unable to read ext4 free-space metadata" >&2
  exit 1
}
FREE_MB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
echo "albus: ext4 ${IMAGE_MB} MiB total, ${FREE_MB} MiB free"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "ERROR: rootfs cannot safely fit in ${IMAGE_MB} MiB; only ${FREE_MB} MiB free (requires ${MIN_FREE_MB})." >&2
  exit 1
fi
gzip -6 -c "$ROOTFS_IMG" > "$OUT_DIR/debian-albus.ext4.gz"
rm -f "$ROOTFS_IMG"

{
  echo "device=$DEVICE"
  echo "device_pretty=$DEVICE_PRETTY"
  echo "distro=debian"
  echo "debian_suite=$DEBIAN_SUITE"
  echo "architecture=arm64"
  echo "kernel_release=$KREL"
  echo "rootfs_label=debian-albus"
  echo "rootfs_uuid=$ROOTFS_EXT4_UUID"
  echo "image_size_mib=$IMAGE_MB"
  echo "image_free_mib=$FREE_MB"
  echo "image_min_free_mib=$MIN_FREE_MB"
  echo "staged_rootfs_mib=$USED_MB"
  echo "usb_device_ip=10.15.0.1"
  echo "usb_dhcp_range=10.15.0.50-10.15.0.200"
  echo "ssh_auth=any-password-over-usb (keyless)"
  echo "ssh_listen=10.15.0.1"
  echo "ssh_scope=usb-only"
  echo "network_manager=NetworkManager"
  echo "usb_network_manager=unmanaged"
  echo "wifi_runtime_setup=nmcli"
} > "$OUT_DIR/build-info.txt"

(
  cd "$OUT_DIR"
  sha256sum debian-albus.ext4.gz build-info.txt > debian-albus.ext4.gz.sha256
)
