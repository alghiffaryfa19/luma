#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Helper script to build Luma OS boot and userdata images for OnePlus 6T (fajita)
set -euo pipefail

WORKSPACE="$(pwd)"
BUILD_DIR="${BUILD_DIR:-$WORKSPACE/build/fajita}"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/images}"
COMMIT="${COMMIT:-}"
TAG="${TAG:-nightly}"
OSTREE_REMOTE_URL="${OSTREE_REMOTE_URL:-https://dl.simplyluma.com/os/repo}"
FIRMWARE_OP_REPO="${FIRMWARE_OP_REPO:-https://gitlab.com/sdm845-mainline/firmware-oneplus-sdm845}"
LINUX_FW_REPO="${LINUX_FW_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git}"
PMAPORTS_REPO="${PMAPORTS_REPO:-https://gitlab.nura.eco/nura/pmaports}"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

echo "=== [1/5] Memeriksa / Membangun Kernel fajita ==="
KERNEL_OUT="$BUILD_DIR/out"
KERNEL_IMAGE="$KERNEL_OUT/arch/arm64/boot/Image.gz"
DTB="$KERNEL_OUT/arch/arm64/boot/dts/qcom/sdm845-oneplus-fajita.dtb"

if [ ! -f "$KERNEL_IMAGE" ] || [ ! -f "$DTB" ]; then
  echo "Mempersiapkan source kernel..."
  python3 scripts/kernel/prepare-source.py \
    --lock config/kernel/oneplus-fajita-7.1-rc1.json \
    --cache "$BUILD_DIR/cache" \
    --output "$BUILD_DIR/linux"

  KERNEL_SRC="$BUILD_DIR/linux/linux/linux-sdm845-7.1-rc1-r0"
  OVERLAY_DIR="$BUILD_DIR/linux/overlay"
  BASE_CFG=$(find "$OVERLAY_DIR" -name "config-postmarketos-qcom-sdm845.aarch64" | head -1)

  mkdir -p "$KERNEL_OUT"
  cp "$BASE_CFG" "$KERNEL_OUT/base.config"
  cp "$KERNEL_OUT/base.config" "$KERNEL_OUT/.config"

  bash "$KERNEL_SRC/scripts/kconfig/merge_config.sh" -m -O "$KERNEL_OUT" \
    "$KERNEL_OUT/base.config" "$WORKSPACE/config/kernel/oneplus-fajita.config"
  make -C "$KERNEL_SRC" LLVM=1 ARCH=arm64 O="$KERNEL_OUT" olddefconfig

  echo "Mengompilasi kernel Image.gz, dtbs, modules..."
  make -C "$KERNEL_SRC" -j"$(nproc)" LLVM=1 ARCH=arm64 O="$KERNEL_OUT" Image.gz dtbs modules
fi

echo "=== [2/5] Mempersiapkan Firmware ==="
FW_DIR="$BUILD_DIR/firmware"
mkdir -p "$FW_DIR"

if [ ! -d "$BUILD_DIR/firmware-op" ]; then
  git clone --depth 1 https://gitlab.com/sdm845-mainline/firmware-oneplus-sdm845 "$BUILD_DIR/firmware-op"
fi
(cd "$BUILD_DIR/firmware-op" && git checkout 3e31a0c3e5a061645c09f805387b49fa9d35acbf || true)

if [ ! -d "$BUILD_DIR/linux-firmware" ]; then
  git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git "$BUILD_DIR/linux-firmware"
fi

# Kumpulkan file firmware sesuai manifest
echo "Mengumpulkan 35 file firmware..."
MANIFEST="$WORKSPACE/devices/oneplus/fajita/firmware.manifest"
OP_LIB="$BUILD_DIR/firmware-op/lib/firmware"
LF_LIB="$BUILD_DIR/linux-firmware"

while IFS=$'\t' read -r type perm hash path link; do
  target="$FW_DIR/$path"
  mkdir -p "$(dirname "$target")"

  if [ "$type" = "D" ]; then
    mkdir -p "$target"
  elif [ "$type" = "L" ]; then
    (cd "$(dirname "$target")" && ln -sf "$link" "$(basename "$target")")
  elif [ "$type" = "F" ]; then
    base="${path%.zst}"
    src=""
    for candidate in "$OP_LIB/$path" "$OP_LIB/$base" "$OP_LIB/postmarketos/$base" "$LF_LIB/$path" "$LF_LIB/$base"; do
      if [ -f "$candidate" ]; then src="$candidate"; break; fi
    done
    if [ -n "$src" ]; then
      if [ "$path" != "$base" ] && [ "${src%.zst}" = "$src" ]; then
        zstd -19 -q -c "$src" > "$target"
      else
        cp -a "$src" "$target"
      fi
    else
      echo "Peringatan: File firmware tidak ditemukan: $path"
    fi
  fi
done < "$MANIFEST"

echo "=== [3/5] Mengambil OSTree Rootfs Commit ==="
REPO_DIR="$BUILD_DIR/ostree-repo"
if [ ! -d "$REPO_DIR" ]; then
  mkdir -p "$REPO_DIR"
  ostree --repo="$REPO_DIR" init --mode=bare-user
  ostree --repo="$REPO_DIR" remote add --no-gpg-verify luma "$OSTREE_REMOTE_URL"
fi

echo "Pulling OSTree commit..."
ostree --repo="$REPO_DIR" pull luma luma/1/aarch64/nightly

if [ -z "$COMMIT" ]; then
  COMMIT=$(ostree --repo="$REPO_DIR" rev-parse luma/1/aarch64/nightly)
fi
echo "Target OSTree commit: $COMMIT"

echo "=== [4/5] Merakit Userdata Image ==="
ROOT_UUID="03797c05-cf87-4eda-adc4-6ce111baf2d3"
BOOT_UUID="032D-57AD"
DISK_RAW="$BUILD_DIR/disk.raw"
MNT_DIR="$BUILD_DIR/mnt"
SIZE="10G"

rm -f "$DISK_RAW"
truncate -s "$SIZE" "$DISK_RAW"
L=$(losetup -b 4096 -fP --show "$DISK_RAW")

cleanup() {
  set +e
  umount -R "$MNT_DIR" 2>/dev/null || true
  losetup -d "$L" 2>/dev/null || true
}
trap cleanup EXIT

sfdisk -q "$L" <<EOF
label: gpt
start=256, size=480MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=LumaBoot
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=LumaRoot
EOF
partx -u "$L" 2>/dev/null || true
[ -b "${L}p1" ] || partx -a "$L" 2>/dev/null || true
udevadm settle 2>/dev/null || true

mkfs.vfat -F 32 -S 4096 -n LUMABOOT -i "${BOOT_UUID//-/}" "${L}p1" >/dev/null
mkfs.ext4 -q -F -L LumaRoot -U "$ROOT_UUID" "${L}p2"

mkdir -p "$MNT_DIR"
mount "${L}p2" "$MNT_DIR"

ostree admin init-fs "$MNT_DIR"
ostree admin os-init --sysroot="$MNT_DIR" luma
ostree --repo="$MNT_DIR/ostree/repo" pull-local "$REPO_DIR" "$COMMIT"
printf '[origin]\nrefspec=luma:luma/1/aarch64/nightly\n' > "$BUILD_DIR/origin"
ostree --repo="$MNT_DIR/ostree/repo" refs --create=luma:luma/1/aarch64/nightly "$COMMIT"
ostree admin deploy --sysroot="$MNT_DIR" --os=luma --origin-file="$BUILD_DIR/origin" "$COMMIT"

DEP="$MNT_DIR/ostree/deploy/luma/deploy/$COMMIT.0"
ln -s "deploy/luma/deploy/$COMMIT.0" "$MNT_DIR/ostree/root.a"
OSTREE_PATH=$(grep -o 'ostree=[^ ]*' "$MNT_DIR"/boot/loader/entries/*.conf | head -1 | cut -d= -f2-)
echo "Extracted OSTree path: $OSTREE_PATH"

# Setup akun default luma:1234
HASH=$(openssl passwd -6 1234)
echo "luma:x:1000:1000:Luma:/home/luma:/bin/bash" >> "$DEP/etc/passwd"
echo "luma:$HASH:20000:0:99999:7:::" >> "$DEP/etc/shadow"
echo "luma:x:1000:" >> "$DEP/etc/group"
echo "luma:!::" >> "$DEP/etc/gshadow"
for g in wheel audio video input render luma-display; do
  if grep -q "^$g:" "$DEP/etc/group"; then
    sed -i "/^$g:/{s/:\$/:luma/;t;s/\$/,luma/}" "$DEP/etc/group"
  fi
done

V="$MNT_DIR/ostree/deploy/luma/var"
mkdir -p "$V/home/luma"
if [ -d "$DEP/etc/skel" ]; then
  cp -a "$DEP/etc/skel/." "$V/home/luma/"
fi
chown -R 1000:1000 "$V/home/luma" || true
chmod 0700 "$V/home/luma" || true

# Salin Firmware dan Modul Kernel ke /var
echo "Memasang firmware ke /var/lib/luma/device-firmware..."
mkdir -p "$V/lib/luma/device-firmware"
cp -a "$FW_DIR/." "$V/lib/luma/device-firmware/"

echo "Memasang modul kernel ke /var/lib/luma/device-modules..."
mkdir -p "$V/lib/luma/device-modules"
make -C "$BUILD_DIR/linux/linux/linux-sdm845-7.1-rc1-r0" LLVM=1 ARCH=arm64 O="$KERNEL_OUT" \
  INSTALL_MOD_PATH="$V/lib/luma/device-modules" modules_install 2>/dev/null || \
  cp -a "$KERNEL_OUT/lib/modules" "$V/lib/luma/device-modules/" 2>/dev/null || true

# Pengaturan SELinux context dasar jika setfiles tersedia
if command -v setfiles >/dev/null && [ -f "$DEP/etc/selinux/targeted/contexts/files/file_contexts" ]; then
  setfiles -r "$DEP" "$DEP/etc/selinux/targeted/contexts/files/file_contexts" "$DEP/etc" 2>/dev/null || true
  setfiles -r "$MNT_DIR/ostree/deploy/luma" "$DEP/etc/selinux/targeted/contexts/files/file_contexts" "$V/home" 2>/dev/null || true
fi

# Ekstrak ostree-prepare-root dan shared libraries untuk initramfs
mkdir -p "$BUILD_DIR/initramfs-ostree"
cp -a "$DEP/usr/lib/ostree/ostree-prepare-root" "$BUILD_DIR/initramfs-ostree/" 2>/dev/null || \
cp -a "$DEP/usr/bin/ostree-prepare-root" "$BUILD_DIR/initramfs-ostree/" 2>/dev/null || true

sync
umount -R "$MNT_DIR"
e2fsck -fy "${L}p2" >/dev/null || [ $? -le 1 ]
losetup -d "$L"
trap - EXIT

echo "Mengonversi ke sparse image..."
img2simg "$DISK_RAW" "$OUT_DIR/luma-fajita-userdata.sparse"
rm -f "$DISK_RAW"
(cd "$OUT_DIR" && sha256sum luma-fajita-userdata.sparse > luma-fajita-userdata.sparse.sha256)

echo "=== [5/5] Merakit Boot Image (luma-fajita-boot.img) ==="
# Siapkan initramfs
INITRAMFS_OUT="$BUILD_DIR/initramfs.cpio.gz"
INITRAMFS_WORK="$BUILD_DIR/initramfs-work"
rm -rf "$INITRAMFS_WORK" && mkdir -p "$INITRAMFS_WORK"

if [ ! -d "$BUILD_DIR/pmaports" ]; then
  git clone --depth 1 "$PMAPORTS_REPO" "$BUILD_DIR/pmaports"
fi

cp -a "$BUILD_DIR/pmaports/main/postmarketos-initramfs/." "$INITRAMFS_WORK/"
if [ -f "$BUILD_DIR/initramfs-ostree/ostree-prepare-root" ]; then
  mkdir -p "$INITRAMFS_WORK/usr/lib/ostree"
  cp -a "$BUILD_DIR/initramfs-ostree/ostree-prepare-root" "$INITRAMFS_WORK/usr/lib/ostree/"
fi

# Pack initramfs minimal
(cd "$INITRAMFS_WORK" && find . | cpio -H newc -o | gzip -9 > "$INITRAMFS_OUT")

# Menggabungkan Image.gz dan DTB
KERNEL_COMBINED="$BUILD_DIR/Image.gz-dtb"
cat "$KERNEL_IMAGE" "$DTB" > "$KERNEL_COMBINED"

CMDLINE="console=ttyMSM0,115200 pmos_rootfsopts=defaults rw enforcing=0 pmos_root_uuid=$ROOT_UUID pmos_boot_uuid=$BOOT_UUID ostree=$OSTREE_PATH"

MKBOOTIMG="${WORKSPACE}/scripts/devices/mkbootimg"
if [ ! -f "$MKBOOTIMG" ]; then
  MKBOOTIMG="mkbootimg"
fi

python3 "$MKBOOTIMG" \
  --kernel "$KERNEL_COMBINED" \
  --ramdisk "$INITRAMFS_OUT" \
  --base 0x00000000 \
  --kernel_offset 0x00008000 \
  --ramdisk_offset 0x01000000 \
  --second_offset 0x00f00000 \
  --tags_offset 0x00000100 \
  --pagesize 4096 \
  --cmdline "$CMDLINE" \
  --output "$OUT_DIR/luma-fajita-boot.img"

(cd "$OUT_DIR" && sha256sum luma-fajita-boot.img > luma-fajita-boot.img.sha256)

echo "=== Selesai! Image dihasilkan di $OUT_DIR ==="
ls -lh "$OUT_DIR"

