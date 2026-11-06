#!/usr/bin/env python3
# Android boot image (header v0) writer.
#
# Layout-compatible with AOSP mkbootimg (header version 0) as parsed by
# lk2nd's app/aboot/bootimg.h (see struct boot_img_hdr_v0):
#   magic[8] kernel{size,addr} ramdisk{size,addr} second{size,addr}
#   tags_addr page_size header_version os_version name[16] cmdline[512]
#   id[8] extra[1024]  (header padded to one page)
# Kernel/ramdisk/second follow, each page-aligned. A plain Image.gz with the
# device DTBs appended is passed via --kernel; a dtb file can be concat'ed
# into the kernel blob by the caller.
#
# No-deps fallback for offline CI use; written for msm8953-albus-mainline.
import argparse
import struct


def pad(data: bytes, page: int) -> bytes:
    return data + b"\x00" * ((-len(data)) % page)


def main() -> None:
    ap = argparse.ArgumentParser(description="Android boot image v0 writer")
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk")
    ap.add_argument("--second")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--base", type=lambda s: int(s, 0), default=0x10000000)
    ap.add_argument(
        "--kernel_offset", type=lambda s: int(s, 0), default=0x00008000
    )
    ap.add_argument(
        "--ramdisk_offset", type=lambda s: int(s, 0), default=0x01000000
    )
    ap.add_argument(
        "--second_offset", type=lambda s: int(s, 0), default=0x00f00000
    )
    ap.add_argument(
        "--tags_offset", type=lambda s: int(s, 0), default=0x00000100
    )
    ap.add_argument("--pagesize", type=int, default=2048)
    ap.add_argument("--board", default="")
    ap.add_argument("--output", required=True)
    a = ap.parse_args()

    page = a.pagesize
    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read() if a.ramdisk else b""
    second = open(a.second, "rb").read() if a.second else b""

    header = struct.pack(
        "<8s10I16s512s8I1024s",
        b"ANDROID!",
        len(kernel),
        a.base + a.kernel_offset,
        len(ramdisk),
        a.base + a.ramdisk_offset,
        len(second),
        a.base + a.second_offset,
        a.base + a.tags_offset,
        page,
        0,  # header_version / dt_size (either interpretation expects 0)
        0,  # os_version / unused
        a.board.encode()[:16].ljust(16, b"\x00"),
        a.cmdline.encode()[:512].ljust(512, b"\x00"),
        0, 0, 0, 0, 0, 0, 0, 0,  # id[8]
        b"\x00" * 1024,  # extra_cmdline
    )

    image = (
        pad(header, page) + pad(kernel, page) + pad(ramdisk, page) + pad(second, page)
    )
    with open(a.output, "wb") as f:
        f.write(image)
    print("wrote", a.output, len(image), "bytes")


if __name__ == "__main__":
    main()
