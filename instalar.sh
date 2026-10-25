#!/bin/bash
# Instala Rescate en este Fedora Kinoite:
#   - /boot/rescate                 (imagen principal)
#   - <btrfs>/rescate               (copia de emergencia, por si /boot se daña)
#   - entradas en GRUB: Rescate, copia, modo seguro, Memtest86+, reiniciar, apagar
#   - servicio que mantiene esas entradas al día tras cada actualización
# Opciones:
#   --limpiar-uefi   borra del menú UEFI las entradas de otros sistemas
#                    (Ubuntu, Kubuntu, Windows, Fedora viejos) y deja solo la actual
#   --desinstalar    quita Rescate
set -euo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

OUT=${RESCATE_OUT:-./out}
REPO=${RESCATE_REPO:-riqgonzalo/rescate}
LIMPIAR=0; DESINSTALAR=0
for a in "$@"; do case "$a" in --limpiar-uefi) LIMPIAR=1;; --desinstalar) DESINSTALAR=1;; esac; done

say() { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
okm() { printf '  \e[32m✔\e[0m %s\n' "$*"; }

grep -q 'ostree=' /proc/cmdline || { echo "Este instalador es para Fedora Atómico (Kinoite/Silverblue)."; exit 1; }
ROOTDEV=$(findmnt -no SOURCE /sysroot | sed 's/\[.*//')
ROOTUUID=$(blkid -s UUID -o value "$ROOTDEV")
TOP=$(mktemp -d)
mount -o subvolid=5 "$ROOTDEV" "$TOP"
trap 'umount "$TOP" 2>/dev/null; rmdir "$TOP"' EXIT
mount -o remount,rw /boot 2>/dev/null || true

if [ $DESINSTALAR = 1 ]; then
  say "Desinstalando Rescate"
  systemctl disable --now rescate-grub.service 2>/dev/null || true
  rm -rf /boot/rescate "$TOP/rescate" /etc/rescate /etc/systemd/system/rescate-grub.service \
         /etc/systemd/system/ostree-finalize-staged.service.d/rescate.conf /boot/grub2/custom.cfg
  systemctl daemon-reload
  okm "Rescate eliminado"; exit 0
fi

# 1. Imagen
if [ ! -f "$OUT/rootfs.img" ]; then
  say "Descargando la imagen de Rescate desde GitHub ($REPO)"
  mkdir -p "$OUT"
  for f in vmlinuz initramfs.img rootfs.img memtest.efi SHA256SUMS; do
    curl -fL --progress-bar -o "$OUT/$f" "https://github.com/$REPO/releases/latest/download/$f"
  done
  (cd "$OUT" && sha256sum -c SHA256SUMS) || { echo "La descarga está dañada."; exit 1; }
fi
for f in vmlinuz initramfs.img rootfs.img; do [ -s "$OUT/$f" ] || { echo "Falta $OUT/$f"; exit 1; }; done

need=$(du -cm "$OUT"/vmlinuz "$OUT"/initramfs.img "$OUT"/rootfs.img | tail -1 | cut -f1)
have=$(( $(df -m --output=avail /boot | tail -1) + $(du -sm /boot/rescate 2>/dev/null | cut -f1 || echo 0) ))
[ "$have" -gt $(( need + 400 )) ] || { echo "No hay espacio suficiente en /boot (necesita ${need} MB + 400 MB de margen)."; exit 1; }

say "Copiando Rescate a /boot/rescate"
mkdir -p /boot/rescate
cp -f "$OUT"/vmlinuz "$OUT"/initramfs.img "$OUT"/rootfs.img /boot/rescate/
[ -f "$OUT/memtest.efi" ] && cp -f "$OUT/memtest.efi" /boot/rescate/
restorecon -R /boot/rescate 2>/dev/null || true
okm "Imagen principal instalada ($(du -sh /boot/rescate | cut -f1))"

say "Guardando copia de emergencia en el disco principal"
mkdir -p "$TOP/rescate"
cp -f "$OUT"/vmlinuz "$OUT"/initramfs.img "$OUT"/rootfs.img "$TOP/rescate/"
okm "Copia de emergencia guardada"

# 2. Servicio que mantiene GRUB al día
say "Instalando entradas de GRUB"
install -Dm0755 src/rescate-grub /etc/rescate/rescate-grub
cat > /etc/systemd/system/rescate-grub.service <<'X'
[Unit]
Description=Rescate: mantener las entradas de emergencia en GRUB
After=local-fs.target
RequiresMountsFor=/boot
[Service]
Type=oneshot
ExecStart=/etc/rescate/rescate-grub /boot
[Install]
WantedBy=multi-user.target
X
mkdir -p /etc/systemd/system/ostree-finalize-staged.service.d
cat > /etc/systemd/system/ostree-finalize-staged.service.d/rescate.conf <<'X'
[Service]
ExecStop=-/etc/rescate/rescate-grub /boot
X
restorecon -R /etc/rescate /etc/systemd/system/rescate-grub.service /etc/systemd/system/ostree-finalize-staged.service.d 2>/dev/null || true
systemctl daemon-reload
systemctl enable rescate-grub.service >/dev/null 2>&1
# Asegurar que grub.cfg lea custom.cfg (los grub.cfg de Fedora ya lo hacen)
if ! grep -q 'custom.cfg' /boot/grub2/grub.cfg; then
  cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.antes-de-rescate
  printf '\nif [ -f $prefix/custom.cfg ]; then\n  source $prefix/custom.cfg\nfi\n' >> /boot/grub2/grub.cfg
  okm "grub.cfg ahora carga las entradas de Rescate"
fi
/etc/rescate/rescate-grub /boot
grep "^menuentry\|^  menuentry" /boot/grub2/custom.cfg | sed -E "s/.*menuentry '([^']*)'.*/  ✔ \1/"

# 3. Menú UEFI
if [ $LIMPIAR = 1 ]; then
  say "Limpiando el menú de arranque UEFI"
  cur=$(efibootmgr | awk '/^BootCurrent/{print $2}')
  efibootmgr -v | grep -E '^Boot[0-9A-F]{4}' | while read -r line; do
    n=${line:4:4}
    [ "$n" = "$cur" ] && continue
    if echo "$line" | grep -qiE 'ubuntu|kubuntu|windows|microsoft|fedora|debian|opensuse|arch|linux boot manager'; then
      efibootmgr -q -b "$n" -B && okm "Eliminada: $(echo "$line" | cut -c10- | cut -f1)"
    fi
  done
  order=$(efibootmgr | awk -F': ' '/^BootOrder/{print $2}')
  efibootmgr -q -o "$cur$(echo ",$order" | sed "s/,$cur//g")"
  # Carpetas de otros sistemas en la partición EFI (se guarda copia antes de borrar)
  for d in /boot/efi/EFI/*/; do
    b=$(basename "$d")
    case "${b,,}" in fedora|boot) continue;; esac
    mkdir -p /var/lib/rescate/esp-copia && cp -a "$d" /var/lib/rescate/esp-copia/
    rm -rf "$d" && okm "Carpeta EFI/$b eliminada (copia en /var/lib/rescate/esp-copia)"
  done
  efibootmgr | sed -n '1,/^Boot[0-9A-F]\{4\}/p;/^Boot[0-9A-F]\{4\}/p' | sort -u | grep -E '^Boot' | sed 's/^/  /'
fi

say "Listo. Al encender verás el menú de GRUB 5 segundos con la opción 'Rescate — reparar Fedora'."
