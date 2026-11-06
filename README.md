# msm8953-albus-mainline · branch `rootfs`

Debian (bookworm, arm64) rootfs image for the **Motorola Moto Z2 Play**
(albus, MSM8953), built in GitHub Actions on top of the latest successful
kernel artifact from the `mainline` branch.

## Branch model

| branch | what it builds | artifact |
|---|---|---|
| `mainline` | kernel + DTB + modules + `boot.img` | `albus-mainline` |
| `rootfs` (this) | Debian rootfs image from the latest kernel artifact | `albus-rootfs` |

## Artifacts (Actions run → `albus-rootfs`)

| file | use |
|---|---|
| `debian-albus.ext4.gz` (+ `.sha256`) | `gzip -d`, then `fastboot flash userdata` |
| `build-info.txt` | image metadata (suite, UUID, free space, USB identity) |

## What ships in the image

- **first contact over USB — keyless**: the gadget link is the RNDIS/NCM
  network served by `usb-gadget` + `usb-dhcp` (device `10.15.0.1/24`,
  DHCP `10.15.0.50-200`). `ssh root@10.15.0.1` accepts **any password**
  (PAM `pam_permit` stack, USB-only listener). The local root password stays
  non-empty for anything outside the USB gadget.
- `albus-resize` grows the filesystem to fill the `userdata` partition on
  first boot (one-shot, finds the root device itself)
- `albus-debug` dumps dmesg/UDC/regulators/remoteproc/Wi-Fi state
- device firmware from
  [albus-firmware](https://gitlab.com/vanadium-oss/msm8953/moto/albus/Mainline/albus-firmware):
  `wlan/` → `qcom/msm8953/motorola/albus/`, `wcnss*`/`mba`/`modem`/`adsp`/
  `venus` → firmware root, `a506_zap*` → `qcom/msm8953/motorola/albus/`
- kernel modules + depmod from the fetched artifact
- Wi-Fi at runtime: `nmcli device wifi connect "SSID" password "secret"`

## Build contract

`sh/fetch-kernel.sh` → latest successful `mainline.yml` run artifact;
`sh/build.sh` → mmdebstrap bookworm arm64, device overlay + firmware +
usb-gadget, `systemctl --root` enablement, chroot `sshd -t` sanity check,
mkfs.ext4 with `-d` staging (`-m 0 -N 32768`), e2fsck, free-space gate,
`debian-albus.ext4.gz` + sha256 + `build-info.txt`.

## Layout (branch `rootfs`)

- `conf/device.conf`, `conf/rootfs.conf`, `conf/usb.conf`, `conf/firmware.conf`
  — device-specific data (manipulation of scripts is not needed for porting)
- `sh/build.sh` — the rootfs builder
- `sh/fetch-kernel.sh` — kernel artifact fetcher
- `sh/usb-gadget` — configfs RNDIS gadget (per-device values in conf/usb.conf)
- `sh/firmware.sh` — generic firmware importer
- `distros/debian/rootfs/` — the device overlay (services, sshd policy,
  NetworkManager policy, albus helpers)
- `.github/workflows/rootfs.yml` — CI
