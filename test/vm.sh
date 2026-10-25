#!/bin/bash
# Máquina virtual de prueba para Rescate (UEFI + NVMe), dentro de un contenedor.
#   vm.sh init            crea disco vacío de 40G y variables UEFI
#   vm.sh rescate         arranca Rescate directamente (kernel+initrd) con un disco "medio"
#   vm.sh disco           arranca desde el disco NVMe (como el equipo real)
#   vm.sh stop | shot FILE.png
set -e
W=${W:-$HOME/.cache/rescate-vm}; OUT=$(cd "$(dirname "$0")/../out" && pwd)
mkdir -p "$W"
qemu() {
  podman rm -f rescate-vm >/dev/null 2>&1 || true
  podman run -d --name rescate-vm --device /dev/kvm -v "$W:/work:Z" -v "$OUT:/out:ro,Z" rescate-qemu \
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 8192 \
      -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
      -drive if=pflash,format=raw,file=/work/vars.fd \
      -drive file=/work/disk.qcow2,if=none,id=nv0 -device nvme,serial=RESCATE01,drive=nv0,bootindex=1 \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
      -serial unix:/work/serial.sock,server,nowait -monitor unix:/work/mon.sock,server,nowait \
      -display none -vga std "$@" >/dev/null
  sleep 2
}
case "$1" in
  init)
    podman run --rm -v "$W:/work:Z" rescate-qemu sh -c 'qemu-img create -f qcow2 /work/disk.qcow2 40G >/dev/null; cp /usr/share/edk2/ovmf/OVMF_VARS.fd /work/vars.fd'
    podman run --rm -v "$W:/work:Z" -v "$OUT:/out:ro,Z" rescate-qemu sh -c 'mkdir -p /tmp/m/rescate && cp /out/vmlinuz /out/initramfs.img /out/rootfs.img /tmp/m/rescate/ && [ -f /out/memtest.efi ] && cp /out/memtest.efi /tmp/m/rescate/; rm -f /work/media.img; truncate -s 3G /work/media.img; mkfs.ext4 -q -L RESCATEMEDIA -d /tmp/m /work/media.img'
    echo listo ;;
  media)
    podman run --rm -v "$W:/work:Z" -v "$OUT:/out:ro,Z" rescate-qemu sh -c 'mkdir -p /tmp/m/rescate && cp /out/vmlinuz /out/initramfs.img /out/rootfs.img /tmp/m/rescate/ && cp /out/memtest.efi /tmp/m/rescate/ 2>/dev/null; rm -f /work/media.img; truncate -s 3G /work/media.img; mkfs.ext4 -q -L RESCATEMEDIA -d /tmp/m /work/media.img'
    echo listo ;;
  rescate)
    qemu -drive file=/work/media.img,format=raw,if=virtio -kernel /out/vmlinuz -initrd /out/initramfs.img \
      -append "root=live:LABEL=RESCATEMEDIA rd.live.dir=/rescate rd.live.squashimg=rootfs.img rd.live.ram=1 rd.live.overlay.overlayfs=1 selinux=0 console=tty0 console=ttyS0,115200 vconsole.keymap=latam" ;;
  disco) qemu -drive file=/work/media.img,format=raw,if=virtio ;;
  stop) podman rm -f rescate-vm >/dev/null 2>&1 || true ;;
  shot) python3 "$(dirname "$0")/mon.py" "$W/mon.sock" "screendump /work/shot.ppm"; sleep 1
        podman run --rm -v "$W:/work:Z" rescate-qemu python3 -c "
import sys
d=open('/work/shot.ppm','rb').read()
" ; cp "$W/shot.ppm" "${2:-/tmp/shot.ppm}" ;;
esac
