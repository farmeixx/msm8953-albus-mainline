# msm8953-albus-mainline

Mainline Linux for the Motorola Moto Z2 Play (albus, MSM8953-Pro), built in
GitHub Actions, plus a Debian rootfs image for it.

**Builder only — patches were authored against
[vanadium-oss/msm8953/Mainline/linux](https://gitlab.com/vanadium-oss/msm8953/Mainline/linux)
(`msm8953/latest`).** Firmware lives at
[`albus-firmware`](https://gitlab.com/vanadium-oss/msm8953/moto/albus/Mainline/albus-firmware).

## Artifacts (Actions run → `albus-mainline`)

| file | use |
|---|---|
| `boot.img` | flashed to the `boot` partition under lk2nd |
| `debian-albus.ext4.gz` | decompress with `gzip -d`, flash to `userdata` |
| `Image.gz` / `msm8953-motorola-albus.dtb` | raw kernel + DTB |
| `modules.tar.gz` | kernel modules (already inside the rootfs) |

## Flashing (needs an unlocked bootloader running **lk2nd ≥ 23**)

```sh
# from the downloaded artifact (unzip first)
gzip -d debian-albus.ext4.gz

fastboot flash boot boot.img
fastboot flash userdata debian-albus.ext4
fastboot reboot
```

`lk2nd` unpacks the gzip'd kernel, picks the appended DTB by
`qcom,msm-id`/`qcom,board-id` and boots it with the stock layout: the
`boot` partition must stay intact — only the `boot` (kernel) content is
replaced, lk2nd lives in its own 512 KiB region before it and is preserved.

## First contact (no working screen needed)

The device boots Debian straight from the `userdata` ext4 partition (no
initramfs). USB comes up as an **RNDIS gadget**:

- device IP: `10.15.0.1` (DHCP hands the host a matching address)
- login: `ssh root@10.15.0.1` — **empty password**

On the device:

```
nmcli device wifi list
nmcli device wifi connect "SSID" password "secret"
```

Debug helpers: `albus-debug` dumps dmesg/USB/UDC/Wi-Fi/mac80211 state to
stdout and `/var/log/albus-debug-*.txt`; rebooting twice saves the previous
kernel log in `/sys/fs/pstore` (ramoops).

## Layout

- `patches/` — kernel patches applied to a fresh `msm8953/latest` clone
- `patches-src/` — author-round copies of the DTS + config fragment
- `scripts/kernel.sh` — clone, patch, defconfig+fragments, `Image.gz dtbs modules`, modules_install, `boot.img`
- `scripts/rootfs.sh` — debootstrap bookworm arm64 (`--foreign` + qemu-user-static), overlay, modules + firmware, 6 GiB ext4
- `overlay/` — first-boot overlay: usb-gadget service (configfs RNDIS + dnsmasq in `/run`), sshd root drop-in, NetworkManager unmanaged-gadget rule, `albus-resize` (grows the rootfs to fill `userdata`)
- `mkbootimg.py` — Android boot image writer (vendored)
