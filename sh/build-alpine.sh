#!/usr/bin/env bash
# Build the Moto Z2 Play (albus) Alpine rootfs image (OpenRC, musl).
# Kernel modules come from the `mainline` branch artifact:
#   KERNEL_MODULES_ARCHIVE, KERNEL_RELEASE (from kernel-release.txt)
set -euo pipefail

: "${KERNEL_RELEASE:?set KERNEL_RELEASE}"
: "${KERNEL_MODULES_ARCHIVE:?set KERNEL_MODULES_ARCHIVE}"
: "${OUT_DIR:?set OUT_DIR}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/conf/rootfs.conf"
source "$ROOT/conf/device.conf"

WORK_DIR="${WORK_DIR:-$ROOT/.work}"
STAGE="$WORK_DIR/rootfs-alpine"
KREL="$KERNEL_RELEASE"

ALPINE_VERSION="${ALPINE_VERSION:?}"
ALPINE_BRANCH="v${ALPINE_VERSION%.*}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_ARCH="aarch64"
APK_TOOLS_STATIC_VERSION="${APK_TOOLS_STATIC_VERSION:?}"

MINIROOTFS="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
MINIROOTFS_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/${MINIROOTFS}"

test -s "$KERNEL_MODULES_ARCHIVE"
mkdir -p "$WORK_DIR" "$OUT_DIR"
sudo rm -rf "$STAGE"
sudo mkdir -p "$STAGE"

#------------------------------------------------------------------#
# Bootstrap the official minirootfs tarball. Package unpacking runs with a
# native static apk on the runner; package scripts and the few chroot
# helpers run under qemu-user (binfmt), like the Debian builder.

curl -fsSL --retry 3 "$MINIROOTFS_URL" -o "$WORK_DIR/$MINIROOTFS"
curl -fsSL --retry 3 "$MINIROOTFS_URL.sha256" -o "$WORK_DIR/$MINIROOTFS.sha256"
(
  cd "$WORK_DIR"
  sha256sum -c "$MINIROOTFS.sha256"
)
sudo tar --numeric-owner -xzf "$WORK_DIR/$MINIROOTFS" -C "$STAGE"

sudo tee "$STAGE/etc/apk/repositories" >/dev/null <<EOF
${ALPINE_MIRROR}/${ALPINE_BRANCH}/main
${ALPINE_MIRROR}/${ALPINE_BRANCH}/community
EOF

# apk needs host resolver access; the tarball's resolv.conf may be a symlink,
# so replace it with a plain copy of the runner's resolver.
sudo rm -f "$STAGE/etc/resolv.conf"
sudo cp /etc/resolv.conf "$STAGE/etc/resolv.conf"

APK_STATIC_PKG="$WORK_DIR/apk-tools-static-$APK_TOOLS_STATIC_VERSION.apk"
APK_STATIC_DIR="$WORK_DIR/apk-static"
APK_STATIC_URL="$ALPINE_MIRROR/$ALPINE_BRANCH/main/x86_64/apk-tools-static-$APK_TOOLS_STATIC_VERSION.apk"

rm -rf "$APK_STATIC_DIR"
mkdir -p "$APK_STATIC_DIR"
curl -fsSL --retry 3 "$APK_STATIC_URL" -o "$APK_STATIC_PKG"
tar -xzf "$APK_STATIC_PKG" -C "$APK_STATIC_DIR" sbin/apk.static
APK_STATIC="$APK_STATIC_DIR/sbin/apk.static"
test -x "$APK_STATIC"

# Verification keys: the minirootfs ships Alpine's trusted keys; point the
# static apk at them with an absolute path (a relative --keys-dir resolves
# against the builder's cwd and misfires).
APK_KEYS_DIR="$WORK_DIR/apk-keys"
rm -rf "$APK_KEYS_DIR"
sudo cp -a "$STAGE/etc/apk/keys" "$APK_KEYS_DIR"
test -n "$(find "$APK_KEYS_DIR" -name 'alpine*.pub' -print -quit)"

# Package scripts/triggers run in the target root. Give them the normal /dev
# interface (notably /dev/null and getrandom consumers) without copying host
# device nodes into the final filesystem image.
cleanup_apk_dev() {
  sudo umount "$STAGE/dev" 2>/dev/null || true
}
trap cleanup_apk_dev EXIT
sudo mkdir -p "$STAGE/dev"
sudo mount --bind /dev "$STAGE/dev"

# Native static apk performs the package file operations; target package
# scripts still run inside the aarch64 root through binfmt/QEMU. This avoids
# QEMU failing while apk preserves SUID perms (dbus-daemon-launch-helper).
sudo "$APK_STATIC" \
  --root "$STAGE" \
  --arch "$ALPINE_ARCH" \
  --keys-dir "$APK_KEYS_DIR" \
  -X "$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
  -X "$ALPINE_MIRROR/$ALPINE_BRANCH/community" \
  --update-cache add \
    openrc busybox-openrc \
    eudev eudev-openrc udev-init-scripts udev-init-scripts-openrc \
    openssh-server openssh-client \
    iproute2 \
    dnsmasq dnsmasq-openrc \
    ca-certificates \
    kmod \
    e2fsprogs e2fsprogs-extra \
    util-linux \
    procps \
    less nano \
    ethtool iw \
    dbus dbus-openrc \
    networkmanager networkmanager-openrc networkmanager-cli networkmanager-wifi \
    wpa_supplicant wireless-regdb \
    openssl \
    tzdata

sudo chroot "$STAGE" /usr/sbin/update-ca-certificates

#------------------------------------------------------------------#

# Device overlay: OpenRC services (USB gadget, dnsmasq USB DHCP, USB-only
# sshd, first-boot resize), the usb-role helper (OpenRC variant) and the
# NetworkManager policy shaped after the Debian image.
sudo cp -a "$ROOT/distros/alpine/rootfs/." "$STAGE/"
sudo chmod 0755 \
  "$STAGE/etc/init.d/usb-gadget" \
  "$STAGE/etc/init.d/usb-sshd" \
  "$STAGE/etc/init.d/albus-resize" \
  "$STAGE/usr/local/bin/usb-role" \
  "$STAGE/usr/local/bin/albus-resize"
# Install original device firmware as regular files; never mount vendor/modem.
bash "$ROOT/sh/firmware.sh" install "$STAGE"
# One shared RNDIS implementation + albus-specific configuration.
sudo install -D -m 0755 "$ROOT/sh/usb-gadget" "$STAGE/usr/local/sbin/usb-gadget"
sudo install -m 0644 "$ROOT/conf/usb.conf" "$STAGE/etc/usb-gadget.conf"
test -x "$STAGE/usr/local/sbin/usb-gadget"
test -s "$STAGE/etc/usb-gadget.conf"
test -x "$STAGE/usr/local/bin/usb-role"
test -x "$STAGE/usr/local/bin/albus-resize"

printf '%s\n' "$DEVICE" | sudo tee "$STAGE/etc/hostname" >/dev/null
sudo tee "$STAGE/etc/hosts" >/dev/null <<HOSTS
127.0.0.1 localhost
127.0.1.1 $DEVICE
::1 localhost ip6-localhost ip6-loopback
HOSTS

sudo tee "$STAGE/etc/fstab" >/dev/null <<FSTAB
PARTLABEL=userdata / ext4 rw,noatime 0 1
FSTAB

# Keep a stable per-image identifier for the USB serial fallback.
if [ ! -s "$STAGE/etc/machine-id" ]; then
  openssl rand -hex 16 | sudo tee "$STAGE/etc/machine-id" >/dev/null
fi

# USB-only open root SSH: Alpine's OpenSSH has no PAM, so the Alpine overlay
# carries its own sshd_config.d fragment (the Debian one needs UsePAM). The
# root password stays empty, but every console getty is removed below.
sudo sed -i 's|^root:[^:]*:|root::|' "$STAGE/etc/shadow"
if ! sudo grep -Fq 'Include /etc/ssh/sshd_config.d/*.conf' "$STAGE/etc/ssh/sshd_config"; then
  sudo sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$STAGE/etc/ssh/sshd_config"
fi

sudo chroot "$STAGE" /usr/bin/ssh-keygen -A

# Explicit OpenRC runlevel set. eudev is the device manager (never mdev and
# udev at once); NetworkManager owns wlan0 and launches wpa_supplicant.
sudo chroot "$STAGE" /sbin/rc-update del mdev sysinit 2>/dev/null || true
for service in devfs procfs sysfs dmesg udev udev-trigger udev-settle; do
  sudo chroot "$STAGE" /sbin/rc-update add "$service" sysinit 2>/dev/null || true
done
for service in hwdrivers modules sysctl hostname bootmisc syslog localmount; do
  sudo chroot "$STAGE" /sbin/rc-update add "$service" boot 2>/dev/null || true
done
for service in udev-postmount dbus usb-gadget dnsmasq usb-sshd networkmanager ntpd albus-resize; do
  sudo chroot "$STAGE" /sbin/rc-update add "$service" default 2>/dev/null || true
done

# Alpine's legacy networking stack and the standalone supplicant stay off.
sudo chroot "$STAGE" /sbin/rc-update del networking boot 2>/dev/null || true
sudo chroot "$STAGE" /sbin/rc-update del wpa_supplicant boot 2>/dev/null || true

# Headless image: no local/serial console getty (the root password is empty).
sudo sed -i -E '/::(respawn|askfirst):.*(a?getty)/d' "$STAGE/etc/inittab"

test -x "$STAGE/sbin/udevd"
for svc in udev udev-trigger udev-settle; do
  test -L "$STAGE/etc/runlevels/sysinit/$svc"
done
for svc in usb-gadget usb-sshd dnsmasq networkmanager ntpd albus-resize udev-postmount dbus; do
  test -L "$STAGE/etc/runlevels/default/$svc"
done
test ! -e "$STAGE/etc/runlevels/sysinit/mdev"
test ! -e "$STAGE/etc/runlevels/boot/networking"
test ! -e "$STAGE/etc/runlevels/boot/wpa_supplicant"
grep -Fqx 'unmanaged-devices=interface-name:usb0' "$STAGE/etc/NetworkManager/conf.d/10-albus.conf"
grep -Fqi 'ListenAddress 10.15.0.1' "$STAGE/etc/ssh/sshd_config.d/10-usb-ssh.conf"

#------------------------------------------------------------------#

# Kernel modules (the archive stores modules-$KREL/lib/modules/$KREL; the
# flat lib/modules layout is accepted too).
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

sudo install -d -m 0755 "$STAGE/run/sshd"
# sshd validates the USB-only configuration before anything ships.
sudo chroot "$STAGE" /usr/sbin/sshd -t

# qemu-aarch64-static is a host-side helper and must not ship in the image.
sudo rm -f "$STAGE/usr/bin/qemu-aarch64-static"

# Package scripts/triggers are done: release the temporary host /dev bind.
cleanup_apk_dev
trap - EXIT

#------------------------------------------------------------------#

# Drop apk's download/index cache; installed packages, firmware and modules
# stay intact.
if [ -d "$STAGE/var/cache/apk" ]; then
  sudo find "$STAGE/var/cache/apk" -maxdepth 1 -type f -delete
fi

USED_MB="$(sudo du -sm "$STAGE" | awk '{print $1}')"
IMAGE_MB="$IMAGE_SIZE_MB"
MIN_FREE_MB="$IMAGE_FREE_MIN_ALPINE"
echo "albus: staged alpine rootfs ${USED_MB} MiB; target ${IMAGE_MB} MiB; minimum free ${MIN_FREE_MB} MiB"

ROOTFS_IMG="$OUT_DIR/alpine-albus.ext4"
truncate -s "${IMAGE_MB}M" "$ROOTFS_IMG"
# Alpine packs fewer files than Debian: a slimmer journal and inode table
# still leave the policy-required free space.
sudo mkfs.ext4 -F -m 0 -N 16384 -J size=8 -L alpine-albus -U random -d "$STAGE" "$ROOTFS_IMG"
test "$(stat -c %s "$ROOTFS_IMG")" -eq $((IMAGE_MB * 1024 * 1024))
ROOTFS_EXT4_UUID="$(blkid -p -o value -s UUID "$ROOTFS_IMG")"
test -n "$ROOTFS_EXT4_UUID"
sudo e2fsck -fn "$ROOTFS_IMG"
test "$(blkid -p -o value -s LABEL "$ROOTFS_IMG")" = "alpine-albus"
FS_STATS="$(sudo tune2fs -l "$ROOTFS_IMG")"
FREE_BLOCKS="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || {
  echo "ERROR: unable to read ext4 free-space metadata" >&2
  exit 1
}
FREE_MB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
echo "albus: alpine ext4 ${IMAGE_MB} MiB total, ${FREE_MB} MiB free"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "ERROR: rootfs cannot safely fit in ${IMAGE_MB} MiB; only ${FREE_MB} MiB free (requires ${MIN_FREE_MB})." >&2
  exit 1
fi

{
  echo "device=$DEVICE"
  echo "device_pretty=$DEVICE_PRETTY"
  echo "distro=alpine"
  echo "alpine_version=$ALPINE_VERSION"
  echo "architecture=arm64"
  echo "init=openrc"
  echo "kernel_release=$KREL"
  echo "rootfs_label=alpine-albus"
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
