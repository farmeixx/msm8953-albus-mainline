# msm8953-albus-mainline · branch `alpine`

Alpine (v3.24, arm64, OpenRC/musl) rootfs image for the **Motorola Moto Z2
Play** (albus, MSM8953), built in GitHub Actions on top of the latest
successful kernel artifact from the `mainline` branch.

## Branch model

| branch | what it builds | artifact |
|---|---|---|
| `mainline` | kernel + DTB + modules + `boot.img` | `albus-mainline` |
| `alpine` (this) | Alpine rootfs + kernel boot image (timestamped) | `alpine` |
| `debian` | Debian rootfs + kernel boot image (timestamped) | `debian` |

## Artifacts (Actions run → download = `alpine.zip`)

| file | use |
|---|---|
| `alpine-<TS>.ext4` | `fastboot flash userdata alpine-<TS>.ext4` |
| `albus-<TS>-mainline.img` | the kernel `boot.img` — `fastboot flash boot albus-<TS>-mainline.img` |
| `SHA256SUMS.txt` | sha256 of both images |

`<TS>` = build timestamp `YYYYMMDDHHMMSS` (UTC) stamped when the artifact is
published; the boot image always comes from the same `mainline` artifact as
the modules inside the ext4.

## What ships in the image

- **first contact over USB — keyless**: the gadget link is the RNDIS/NCM
  network served by `usb-gadget` + `dnsmasq` (device `10.15.0.1/24`, DHCP
  `10.15.0.50-200`). Alpine's OpenSSH has no PAM, so the root account is
  left passwordless and every console getty is removed; the USB-only
  listener accepts any password. `ssh root@10.15.0.1` is the first contact.
- `albus-resize` grows the filesystem to fill the `userdata` partition on
  first boot (one-shot, finds the root device itself)
- device firmware from
  [albus-firmware](https://gitlab.com/vanadium-oss/msm8953/moto/albus/Mainline/albus-firmware):
  `wlan/` → `qcom/msm8953/motorola/albus/`, `wcnss*`/`mba`/`modem`/`adsp`/
  `venus` → firmware root, `a506_zap*` → `qcom/msm8953/motorola/albus/`
- kernel modules + depmod from the fetched artifact
- Wi-Fi at runtime: `nmcli device wifi connect "SSID" password "secret"`
- OpenRC services: `usb-gadget`, `usb-sshd`, `dnsmasq`, `networkmanager`,
  `albus-resize`, `udev` (never `mdev`)

## Build contract

`sh/fetch-kernel.sh` → latest successful `mainline.yml` run artifact;
`sh/build-alpine.sh` → official Alpine minirootfs, `apk-tools-static`
resolved from the `APKINDEX` of the `v3.24` branch (always the newest
published revision), package install via static apk + qemu-user, device
overlay + firmware + usb-gadget, OpenRC enablement, chroot `sshd -t`
sanity check, mkfs.ext4 with `-d` staging (`-m 0 -N 16384`), e2fsck,
free-space gate; the workflow stamps `alpine-<TS>.ext4` +
`albus-<TS>-mainline.img` + `SHA256SUMS.txt` when publishing the `alpine`
artifact.

## Layout (branch `alpine`)

- `conf/device.conf`, `conf/alpine.conf`, `conf/usb.conf`, `conf/firmware.conf`
  — device-specific data (manipulation of scripts is not needed for porting)
- `sh/build-alpine.sh` — the Alpine rootfs builder
- `sh/fetch-kernel.sh` — kernel artifact fetcher
- `sh/usb-gadget` — configfs RNDIS gadget (per-device values in conf/usb.conf)
- `sh/firmware.sh` — generic firmware importer
- `distros/alpine/rootfs/` — the device overlay (OpenRC services, sshd policy,
  NetworkManager policy, albus helpers)
- `.github/workflows/alpine.yml` — CI (dispatchable; the workflow file also
  exists on the default branch `mainline` so GitHub can register it — when
  dispatching, pick the `alpine` branch)
