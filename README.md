# msm8953-albus-mainline · branch `mainline`

Mainline Linux for the **Motorola Moto Z2 Play (albus, MSM8953)**, built in
GitHub Actions.

**Builder only — patches are authored against
[vanadium-oss/msm8953/Mainline/linux](https://gitlab.com/vanadium-oss/msm8953/Mainline/linux)
(`msm8953/latest`).** Device firmware lives at
[albus-firmware](https://gitlab.com/vanadium-oss/msm8953/moto/albus/Mainline/albus-firmware)
(GitLab) and is installed by the `rootfs` branch.

## Branch model

| branch | what it builds | artifact |
|---|---|---|
| `mainline` (this) | kernel + DTB + modules + `boot.img` | `albus-mainline` |
| `rootfs` | Debian rootfs image from the latest `mainline` artifact | `albus-rootfs` |

## Artifacts (Actions run → `albus-mainline`)

| file | use |
|---|---|
| `boot.img` (+ `boot.img.sha256`) | flashed to the `boot` partition under lk2nd |
| `Image.gz` / `msm8953-motorola-albus.dtb` | raw kernel + DTB |
| `modules.tar.gz` | kernel modules (consumed by the `rootfs` branch) |
| `kernel-release.txt` | module tree name (consumed by the `rootfs` branch) |

## Build contract

- clone `msm8953/latest`, apply `patches/*.patch`
- `defconfig` → merge `msm8953.config` + `motorola-albus.config` → `olddefconfig`
- essentials asserted built-in: ext4(+security), configfs gadget RNDIS/NCM/ECM, DWC3 QCOM, gpio-keys
- `Image.gz dtbs modules` + `modules_install`
- `boot.img` = `Image.gz || msm8953-motorola-albus.dtb`, cmdline
  `root=PARTLABEL=userdata rw rootwait` (rootfs-agnostic), msm8953 boot offsets,
  page size 2048 — written by the vendored `mkbootimg.py`

## Flashing (needs an unlocked bootloader running **lk2nd ≥ 23**)

```sh
gzip -d debian-albus.ext4.gz   # from the `rootfs` branch artifact

fastboot flash boot boot.img
fastboot flash userdata debian-albus.ext4
fastboot reboot
```

`lk2nd` unpacks the gzip'd kernel, picks the appended DTB by `qcom,msm-id` /
`qcom,board-id` and boots it with the stock layout: lk2nd lives in its own
512 KiB region before the `boot` partition and is preserved.

## First contact (needs no working screen)

The device boots Debian straight from the `userdata` ext4 partition (no
initramfs). USB comes up as an **RNDIS/NCM gadget** (`usb-gadget` service):

- device IP: `10.15.0.1` (DHCP hands the host an address in `10.15.0.50-200`)
- login: `ssh root@10.15.0.1` — **any password** (keyless, USB-only stack)

Wi-Fi runs through NetworkManager on the device:

```
nmcli device wifi list
nmcli device wifi connect "SSID" password "secret"
```

Debug helper: `albus-debug` dumps dmesg/USB/UDC/Wi-Fi state to stdout and
`/var/log/albus-debug-*.txt`; rebooting twice saves the previous kernel log in
`/sys/fs/pstore` (ramoops); `albus-resize` grows the rootfs to fill `userdata`
on first boot.

## Layout (branch `mainline`)

- `patches/` — kernel patches (DTS + config fragment) applied to a fresh
  `msm8953/latest` clone
- `patches-src/` — author-round copies of the DTS + config fragment
- `scripts/kernel.sh` — clone, patch, defconfig+fragments, `Image.gz dtbs
  modules`, `modules_install`, `boot.img`
- `mkbootimg.py` — Android boot image writer (vendored)
- `conf/mainline.conf` — device build configuration (documents exactly what
  the branch builds)
- `.github/workflows/mainline.yml` — CI: cache-keyed kernel build + artifact
