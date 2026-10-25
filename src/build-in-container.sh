#!/bin/bash
# Construye el mini-Fedora de rescate. Se ejecuta dentro de un contenedor fedora:44.
set -euo pipefail
R=/rootfs
OUT=/out
PKGS=(
  systemd systemd-udev systemd-resolved bash bash-completion coreutils util-linux util-linux-core
  procps-ng findutils grep sed gawk which less nano vim-minimal tar rsync kbd glibc-langpack-es
  kernel-core kernel-modules-core kernel-modules dracut dracut-live
  NetworkManager NetworkManager-wifi NetworkManager-tui NetworkManager-bluetooth wpa_supplicant iw iproute iputils
  ca-certificates curl bluez rfkill psmisc attr shadow-utils fedora-gpg-keys
  linux-firmware iwlwifi-mvm-firmware iwlwifi-dvm-firmware iwlbluetooth-firmware realtek-firmware intel-gpu-firmware
  atheros-firmware mt7xxx-firmware brcmfmac-firmware nvidia-gpu-firmware amd-gpu-firmware
  mesa-vulkan-drivers vulkan-loader vulkan-tools memtester stress-ng lm_sensors memtest86+
  newt efibootmgr mokutil grub2-efi-x64 grub2-tools grub2-tools-minimal shim-x64
  btrfs-progs e2fsprogs dosfstools gdisk parted diffutils
  ostree rpm-ostree
  pciutils usbutils smartmontools nvme-cli
)
dnf -y install --setopt=install_weak_deps=False squashfs-tools >/dev/null
mkdir -p $R
dnf -y --installroot=$R --releasever=44 --use-host-config \
    --setopt=install_weak_deps=False --setopt=tsflags=nodocs install "${PKGS[@]}"

# --- Configuración del sistema de rescate ---
echo rescate > $R/etc/hostname
printf 'KEYMAP=latam\nFONT=eurlatgr\n' > $R/etc/vconsole.conf
echo 'LANG=es_ES.UTF-8' > $R/etc/locale.conf
ln -sf ../usr/share/zoneinfo/America/Mexico_City $R/etc/localtime 2>/dev/null || true
: > $R/etc/machine-id
sed -i 's/^root:[^:]*:/root::/' $R/etc/shadow          # root sin contraseña (solo en el rescate)
for g in getty serial-getty; do
mkdir -p $R/etc/systemd/system/$g@.service.d
cat > $R/etc/systemd/system/$g@.service.d/autologin.conf <<'X'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,38400,9600 %I $TERM
X
done
cat > $R/root/.bash_profile <<'X'
[ -f ~/.bashrc ] && . ~/.bashrc
if [ "$(tty)" = /dev/tty1 ]; then
  setfont eurlatgr 2>/dev/null; dmesg -n 1 2>/dev/null
  /usr/local/sbin/rescate
fi
X
# nouveau no se carga solo (evita cuelgues); la prueba de VRAM lo carga a mano
printf 'blacklist nouveau\nblacklist nova_core\n' > $R/etc/modprobe.d/rescate-gpu.conf
ln -sf /usr/lib/systemd/system/multi-user.target $R/etc/systemd/system/default.target
chroot $R systemctl enable NetworkManager systemd-resolved bluetooth >/dev/null 2>&1 || true
chroot $R systemctl disable NetworkManager-wait-online >/dev/null 2>&1 || true
ln -sf ../run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf
# Rescate corre desde la RAM: soltar el disco de origen (/boot) para poder repararlo
cat > $R/etc/systemd/system/rescate-liberar.service <<'X'
[Unit]
Description=Rescate: liberar el disco de origen (todo corre en RAM)
DefaultDependencies=no
After=local-fs.target
Before=getty@tty1.service serial-getty@ttyS0.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -s /run/initramfs/squashed.img ] && mountpoint -q /run/initramfs/live; then umount /run/initramfs/live || umount -l /run/initramfs/live; fi'
[Install]
WantedBy=multi-user.target
X
chroot $R systemctl enable rescate-liberar.service >/dev/null 2>&1
install -m 0755 /src/rescate $R/usr/local/sbin/rescate
install -m 0755 /src/rescate-lib.sh $R/usr/local/sbin/rescate-lib.sh
install -m 0755 /src/rescate-grub $R/usr/local/sbin/rescate-grub
mkdir -p $R/usr/local/share/rescate
install -m 0644 /src/fedora.conf $R/usr/local/share/rescate/fedora.conf
# Prueba de VRAM (memtest_vulkan)
mkdir -p /tmp/mv && curl -fsSL -o /tmp/mv/mv.tar.xz https://github.com/GpuZelenograd/memtest_vulkan/releases/download/v0.5.0/memtest_vulkan-v0.5.0_DesktopLinux_X86_64.tar.xz
tar -xJf /tmp/mv/mv.tar.xz -C /tmp/mv && install -m 0755 "$(find /tmp/mv -type f -name memtest_vulkan | head -1)" $R/usr/local/bin/memtest_vulkan
# Memtest86+ (EFI)
MT=$(find $R/usr/lib64 $R/usr/lib $R/boot -iname 'memtest*x64*.efi' 2>/dev/null | head -1)
[ -n "$MT" ] && cp "$MT" $OUT/memtest.efi

# --- Kernel + initramfs ---
KVER=$(ls $R/usr/lib/modules | sort -V | tail -1)
cp $R/usr/lib/modules/$KVER/vmlinuz $OUT/vmlinuz
mount --bind /proc $R/proc 2>/dev/null || true
chroot $R dracut --no-hostonly --no-hostonly-cmdline --force \
   --add "dmsquash-live" --omit "plymouth network-manager network" --compress zstd /tmp/initramfs.img $KVER
mv $R/tmp/initramfs.img $OUT/initramfs.img
umount $R/proc 2>/dev/null || true
echo "$KVER" > $OUT/kernel-version
cp $OUT/vmlinuz $OUT/initramfs.img $R/usr/local/share/rescate/
[ -f $OUT/memtest.efi ] && cp $OUT/memtest.efi $R/usr/local/share/rescate/

# --- Adelgazar ---
rm -rf $R/var/cache/dnf $R/var/cache/libdnf5 $R/var/lib/dnf/repos $R/usr/share/doc $R/usr/share/man $R/usr/share/info
rm -f $R/usr/bin/podman $R/usr/bin/skopeo $R/usr/bin/bootc $R/usr/libexec/podman/* 2>/dev/null
find $R/usr -name __pycache__ -type d -prune -exec rm -rf {} +
rm -rf $R/usr/lib/firmware/amdgpu $R/usr/lib/firmware/radeon $R/usr/lib/firmware/qcom $R/usr/lib/firmware/intel/sof* $R/usr/lib/firmware/intel/vpu $R/usr/lib/firmware/intel/ipu
find $R/usr/lib/firmware/nvidia -mindepth 1 -maxdepth 1 ! -name 'ga1*' ! -name 'tu1*' ! -name 'ad1*' -exec rm -rf {} +
# Vulkan: solo NVIDIA libre (NVK) e Intel, que es lo que usa la prueba de VRAM
for f in $R/usr/lib64/libvulkan_*.so; do case "$f" in *nouveau*|*intel.so) ;; *) rm -f "$f";; esac; done
for f in $R/usr/share/vulkan/icd.d/*.json; do case "$f" in *nouveau*|*intel_icd*) ;; *) rm -f "$f";; esac; done
if ! chroot $R ldd /usr/lib64/libvulkan_nouveau.so /usr/lib64/libvulkan_intel.so 2>/dev/null | grep -q LLVM; then
  rm -rf $R/usr/lib64/dri $R/usr/lib64/libLLVM* $R/usr/lib64/libgallium* 2>/dev/null
fi
KM=$R/usr/lib/modules/$KVER/kernel
rm -rf $KM/sound $KM/drivers/media $KM/drivers/infiniband $KM/drivers/isdn $KM/drivers/staging $KM/drivers/gpu/drm/amd $KM/drivers/gpu/drm/radeon $KM/drivers/iio $KM/drivers/fpga $KM/net/wireless/../mac802154 2>/dev/null
chroot $R depmod -a $KVER
find $R/usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'es*' -exec rm -rf {} + 
rm -rf $R/boot/*

# --- Imagen comprimida ---
rm -f $OUT/rootfs.img
mksquashfs $R $OUT/rootfs.img -comp zstd -Xcompression-level 19 -noappend -quiet
date -u +%Y-%m-%d > $OUT/build-date
ls -lh $OUT
