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
# Optional: xorriso + isolinux (BIOS-bootable weaver.iso)
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)          # repo root
OUT=$HERE/kernel/out
IMAGE=$OUT/weaver.qcow2
SQFS=$OUT/weaver-root.squashfs
ISO=$OUT/weaver.iso

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

# ---------- ISO (El Torito, BIOS isolinux) ----------
# A real install medium: BIOS firmware loads isolinux from the CD,
# isolinux loads our kernel, kernel boots the baked-in initramfs.
# The squashfs rides along as a data file for later stages (root-on-disk).
if command -v xorriso >/dev/null 2>&1 && [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
	echo "==> building BIOS-bootable ISO"
	ISODIR=$OUT/iso
	ISOLINUX=/usr/lib/ISOLINUX/isolinux.bin
	rm -rf "$ISODIR" "$ISO"
	mkdir -p "$ISODIR/isolinux" "$ISODIR/svos"

	# kernel + squashfs as ISO payload
	cp "$OUT/linux-6.1.188/arch/x86/boot/bzImage" "$ISODIR/svos/vmlinuz"
	cp "$SQFS" "$ISODIR/svos/root.squashfs"
	# the bootloader itself must live in the tree xorriso packs
	cp /usr/lib/ISOLINUX/isolinux.bin "$ISODIR/isolinux/isolinux.bin"
	# syslinux 6.04 needs its core module next to the binary
	cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISODIR/isolinux/ldlinux.c32"

	# isolinux boot config: serial console, same cmdline as -kernel
	cat > "$ISODIR/isolinux/isolinux.cfg" <<EOF
SERIAL 0 115200
DEFAULT weaver
PROMPT 0
TIMEOUT 1
LABEL weaver
	KERNEL /svos/vmlinuz
	APPEND console=ttyS0 rdinit=/init quiet
EOF

	# -isohybrid-mbr makes the ISO also bootable from USB (BIOS)
	xorriso -as mkisofs \
		-o "$ISO" \
		-isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
		-c isolinux/boot.cat \
		-b isolinux/isolinux.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		-V WEAVERR "$ISODIR" >/dev/null

	ls -la "$ISO"
	echo "==> ISO ready: $ISO"
	echo "    boot with: qemu-system-x86_64 -m 512 -cdrom $ISO -nographic"
else
	echo "==> skipping ISO (xorriso/isolinux missing on host)"
fi