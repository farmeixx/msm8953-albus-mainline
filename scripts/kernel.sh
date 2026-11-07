#!/usr/bin/env bash
# Build the msm8953 mainline kernel (the albus DTS and config fragment are
# committed in the same repository) and pack boot.img.
set -euxo pipefail

ROOT="$PWD"
OUT="$ROOT/out"
SRC="$ROOT/kernel-src"
rm -rf "$OUT"
mkdir -p "$OUT"

rm -rf "$SRC"
git clone --depth 1 --branch msm8953/latest \
	https://gitlab.com/vanadium-oss/msm8953/Mainline/linux.git "$SRC"
cd "$SRC"

test -s arch/arm64/boot/dts/qcom/msm8953-motorola-albus.dts
test -s arch/arm64/configs/msm8953.config
test -s arch/arm64/configs/motorola-albus.config

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
scripts/kconfig/merge_config.sh -m .config \
	arch/arm64/configs/msm8953.config \
	arch/arm64/configs/motorola-albus.config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

# The Debian root has no initramfs; make sure the essentials are built in.
: "$(grep -q '^CONFIG_EXT4_FS=y' .config)"
: "$(grep -q '^CONFIG_EXT4_FS_SECURITY=y' .config)"
: "$(grep -q '^CONFIG_USB_CONFIGFS_RNDIS=y' .config)"
: "$(grep -q '^CONFIG_USB_DWC3_QCOM=y' .config)"
: "$(grep -q '^CONFIG_KEYBOARD_GPIO=y' .config)"

make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image.gz dtbs modules

DTB=arch/arm64/boot/dts/qcom/msm8953-motorola-albus.dtb
test -s "$DTB"

KREL="$(make -s ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease)"
echo "kernel release: $KREL"
echo "$KREL" > "$OUT/kernel-release.txt"

MODDIR="$OUT/modules-$KREL"
mkdir -p "$MODDIR"
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
	modules_install INSTALL_MOD_PATH="$(readlink -f "$MODDIR")"
tar -czf "$OUT/modules.tar.gz" -C "$OUT" "modules-$KREL"

cp arch/arm64/boot/Image.gz "$OUT/Image.gz"
cp "$DTB" "$OUT/msm8953-motorola-albus.dtb"

# lk2nd decompresses the gzip'd kernel and scans appended FDTs right after
# the decompressed image; it selects the DTB matching qcom,msm-id/board-id.
cat "$OUT/Image.gz" "$OUT/msm8953-motorola-albus.dtb" > "$OUT/kernel-albus-dtb.img"
python3 "$ROOT/mkbootimg.py" \
	--kernel "$OUT/kernel-albus-dtb.img" \
	--cmdline "root=PARTLABEL=userdata rw rootwait" \
	--base 0x80000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x00000100 \
	--pagesize 2048 \
	--output "$OUT/boot.img"

sha256sum "$OUT/boot.img" > "$OUT/boot.img.sha256"
