#!/bin/sh
# mkimage.sh — Stage 2d: build the Weaver bootable disk artifact.
#
# Produces out/weaver.qcow2: a disk image with a squashfs root partition
# holding the userland, bootable by QEMU with our bzImage via -kernel.
#
# Why squashfs-on-disk and not everything in the initramfs?
#   - the initramfs (RAM) stays tiny: kernel + svos-init + a few tools
#   - the system's real userland lives on disk, compressed, immutable,
#     mounted read-only at / — upgrades = replace the squashfs
#   - this is the Talos/initramfs-first shape from the roadmap
#
# Dependencies (host): mksquashfs (squashfs-tools), qemu-img (qemu-utils)
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)          # repo root
OUT=$HERE/kernel/out
IMAGE=$OUT/weaver.qcow2
SQFS=$OUT/weaver-root.squashfs

command -v mksquashfs >/dev/null || { echo "mksquashfs not found (apt install squashfs-tools)" >&2; exit 1; }
command -v qemu-img   >/dev/null || { echo "qemu-img not found (apt install qemu-utils)" >&2; exit 1; }
[ -f "$OUT/rootfs/bin/busybox" ] || { echo "rootfs not built — run ./kernel/build.sh first" >&2; exit 1; }

echo "==> packing userland squashfs"
rm -f "$SQFS" "$IMAGE"
# squash the whole rootfs: busybox + init scripts; svos-init stays in the
# initramfs as /init, everything else is loaded from here at boot
mksquashfs "$OUT/rootfs" "$SQFS" \
	-comp xz -noappend -quiet -no-progress \
	-root-mode 0755 -all-root

echo "==> building qcow2 disk image"
qemu-img create -f qcow2 "$IMAGE" 64M >/dev/null
# raw-wrap the squashfs so the guest can mount it as /dev/vda directly:
# a plain raw image of the squashfs is the simplest correct layout for now
# (no partition table yet — that arrives with real bootloader work)
qemu-img convert -f raw -O qcow2 "$SQFS" "$IMAGE" >/dev/null

ls -la "$IMAGE"
echo "==> artifact ready: $IMAGE"
echo "    boot with: qemu-system-x86_64 -m 512 \\"
echo "      -kernel $OUT/linux-6.1.188/arch/x86/boot/bzImage \\"
echo "      -append 'console=ttyS0 rdinit=/init' -nographic \\"
echo "      -drive file=$IMAGE,format=qcow2,if=virtio,readonly=on"