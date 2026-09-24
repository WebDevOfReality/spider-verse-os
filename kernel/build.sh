#!/bin/sh
# Stage 1 — build the Spider-Verse OS kernel + initramfs (Weaver core).
#
# 1. Build busybox statically with our Stage 0 cross-toolchain
# 2. Build Linux (tinyconfig + Weaver fragments) with the same toolchain
# 3. Pack busybox + rootfs/init into the initramfs (kernel bakes it in)
# 4. Smoke test: QEMU direct kernel boot to a busybox shell on serial
#
# Usage: ./kernel/build.sh
# Requires: Stage 0 toolchain (toolchain/out/toolchain), cpio, gzip, wget,
#           xz, bzip2, bc, libelf-dev, libssl-dev, qemu-system-x86
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OUT="$HERE/out"
TOOLCHAIN="$ROOT/toolchain/out/toolchain/bin"
PATH="$TOOLCHAIN:$PATH"
export PATH
TARGET=x86_64-svos-linux-musl
CROSS="${TARGET}-"

KERNEL_VERSION=6.1.188
KERNEL_SHA256=ed4d0acb1307c235230c89efc094e210e6290593f94a7e617f28b1001101a33a
BUSYBOX_VERSION=1.38.0
BUSYBOX_SHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2

KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"

fetch_verify() {
	# fetch_verify <url> <sha256> <dest>
	url=$1; sum=$2; dest=$3
	if [ -f "$dest" ]; then return 0; fi
	wget -q -O "$dest.tmp" "$url"
	echo "$sum  $dest.tmp" | (cd "$(dirname "$dest")" && sha256sum -c -)
	mv "$dest.tmp" "$dest"
}

mkdir -p "$OUT"
cd "$OUT"

# ---------- 0. host sanity ----------
for tool in cpio gzip find bc; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing host tool: $tool" >&2; exit 1; }
done
[ -x "$TOOLCHAIN/${CROSS}gcc" ] || {
	echo "Stage 0 toolchain missing at $TOOLCHAIN — run ./toolchain/build.sh first" >&2
	exit 1
}

# ---------- 1. busybox (static, musl) ----------
if [ ! -x rootfs/bin/busybox ] || [ ! -f rootfs/init ]; then
	fetch_verify "$BUSYBOX_URL" "$BUSYBOX_SHA256" "busybox-${BUSYBOX_VERSION}.tar.bz2"
	rm -rf "busybox-${BUSYBOX_VERSION}"
	tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2"
	cd "busybox-${BUSYBOX_VERSION}"
	yes "" | make -j"$(nproc)" defconfig ARCH=x86_64 CROSS_COMPILE="$CROSS"
	# static build, no debug noise, init built in
	sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
	make -j"$(nproc)" CROSS_COMPILE="$CROSS"
	cd ..
	mkdir -p rootfs/bin
	cp "busybox-${BUSYBOX_VERSION}/busybox" rootfs/bin/busybox
	"$HERE/rootfs/populate" rootfs/bin/busybox rootfs
	cp "$HERE/rootfs/init" rootfs/init
	chmod +x rootfs/init
	# svos-init (Stage 2): our own PID 1, built from source
	# rootfs/init is a shim that execs it so the kernel sees a scriptable
	# entry point; svos-init itself is a static ELF at /sbin/svos-init
	make -C "$HERE/../init" check >/dev/null
	cp "$HERE/../init/svos-init" rootfs/sbin/svos-init
	# etc: inittab + init.d boot/shutdown scripts (busybox-init fallback)
	mkdir -p rootfs/etc/init.d
	cp "$HERE/rootfs/etc/inittab" rootfs/etc/inittab
	cp "$HERE/rootfs/etc/init.d/rcS" rootfs/etc/init.d/rcS
	cp "$HERE/rootfs/etc/init.d/rcK" rootfs/etc/init.d/rcK
	chmod +x rootfs/etc/init.d/rcS rootfs/etc/init.d/rcK
	file rootfs/bin/busybox | grep -q 'statically linked' || {
		echo "busybox is not static — aborting" >&2; exit 1
	}
fi

# ---------- 2. kernel ----------
if [ ! -f "linux-${KERNEL_VERSION}/arch/x86/boot/bzImage" ]; then
	fetch_verify "$KERNEL_URL" "$KERNEL_SHA256" "linux-${KERNEL_VERSION}.tar.xz"
	rm -rf "linux-${KERNEL_VERSION}"
	tar xf "linux-${KERNEL_VERSION}.tar.xz"
	cd "linux-${KERNEL_VERSION}"

	# allnoconfig + KCONFIG_ALLCONFIG is the kernel's supported way to
	# merge a fragment over a "no-everything" base: options the base
	# leaves unset get their dependency-settled defaults.
	make -j"$(nproc)" ARCH=x86 CROSS_COMPILE="$CROSS" \
		KCONFIG_ALLCONFIG="$HERE/config.svos" allnoconfig
	yes '' | make ARCH=x86 CROSS_COMPILE="$CROSS" olddefconfig
	# bake the initramfs: point the kernel at our busybox rootfs
	printf 'CONFIG_INITRAMFS_SOURCE="%s/rootfs"\n' "$OUT" > .initramfs-fragment
	scripts/kconfig/merge_config.sh -m .config .initramfs-fragment >/dev/null
	rm -f .initramfs-fragment
	yes '' | make ARCH=x86 CROSS_COMPILE="$CROSS" olddefconfig
	grep -q "^CONFIG_INITRAMFS_SOURCE=.*rootfs" .config || {
		echo "INITRAMFS_SOURCE not set — aborting" >&2; exit 1
	}
	cd ..
fi

# ---------- 3. verify initramfs is wired ----------
CONFIG_INITRAMFS_SOURCE=$(sed -n 's/^CONFIG_INITRAMFS_SOURCE="\(.*\)"$/\1/p' \
	"linux-${KERNEL_VERSION}/.config")
echo "==> initramfs source: $CONFIG_INITRAMFS_SOURCE"

# ---------- 4. build kernel (bakes rootfs into bzImage) ----------
cd "linux-${KERNEL_VERSION}"
make -j"$(nproc)" ARCH=x86 CROSS_COMPILE="$CROSS" bzImage
cd ..

# ---------- 5. smoke test: QEMU direct kernel boot ----------
echo "==> smoke test: booting bzImage in QEMU"
# drive the serial console: wait for banner, run a marker command, power off
{
	sleep 8
	echo 'echo SVOS-MARKER-$((6*7))'
	sleep 3
	echo 'poweroff -f'
	sleep 5
} | timeout 90 qemu-system-x86_64 \
	-m 256 \
	-kernel "linux-${KERNEL_VERSION}/arch/x86/boot/bzImage" \
	-append 'console=ttyS0 rdinit=/init panic=-1' \
	-nographic -no-reboot > qemu.log 2>&1 || true
grep -aq 'web-spinner' qemu.log && echo '==> PASS: weaver banner on serial' || {
	echo '==> FAIL: no weaver banner in qemu.log' >&2
	tail -20 qemu.log
	exit 1
}
grep -aq 'SVOS-MARKER-42' qemu.log && echo '==> PASS: shell executes commands' || {
	echo '==> FAIL: shell did not answer' >&2
	exit 1
}

# ---------- 6. bootable artifact (Stage 2d) ----------
# squashfs userland on a qcow2 disk, mountable as /dev/vda in the guest.
# Best-effort: needs mksquashfs + qemu-img on the host.
if command -v mksquashfs >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
	echo "==> building disk artifact (weaver.qcow2)"
	sh "$HERE/../scripts/mkimage.sh" || {
		echo '==> FAIL: mkimage.sh failed' >&2
		exit 1
	}
	# verify the artifact actually mounts in the guest
	{
		sleep 8
		echo 'mkdir /sq; mount -t squashfs /dev/vda /sq && echo SQFS-ARTIFACT-OK; umount /sq'
		sleep 3
		echo 'poweroff -f'
		sleep 5
	} | timeout 60 qemu-system-x86_64 \
		-m 512 \
		-kernel "linux-${KERNEL_VERSION}/arch/x86/boot/bzImage" \
		-append 'console=ttyS0 rdinit=/init panic=-1' \
		-nographic -no-reboot \
		-drive file="$OUT/weaver.qcow2",format=qcow2,if=virtio,readonly=on \
		> qemu-image.log 2>&1 || true
	grep -aq 'SQFS-ARTIFACT-OK' qemu-image.log && echo '==> PASS: artifact mounts in guest' || {
		echo '==> FAIL: image did not mount in guest' >&2
		tail -20 qemu-image.log
		exit 1
	}
else
	echo "==> skipping disk artifact (mksquashfs/qemu-img missing on host)"
fi

echo "==> Stage 2 complete."