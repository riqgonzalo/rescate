#!/bin/bash
# Rescate — funciones de detección y reparación para Fedora Kinoite (ostree).
# Lo usan el menú (/usr/local/sbin/rescate) y la línea de órdenes.

LOG=/root/rescate.log
SYSROOT=/mnt/sysroot
PROBE=/mnt/rescate-probe
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
NVIDIA_KARGS="rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1"
INTEL_ONLY_KARGS="rd.driver.blacklist=nvidia modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm"
FEDORA_VER=44

# ---------------------------------------------------------------- utilidades
log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG" >&2; }
ok()   { log "  ✔ $*"; }
warn() { log "  ⚠ $*"; WARNINGS+=("$*"); }
fixd() { log "  ✚ ARREGLADO: $*"; FIXES+=("$*"); }
die()  { log "  ✖ $*"; return 1; }
run()  { log "  \$ $*"; "$@" >>"$LOG" 2>&1; }

have_tty() { [ -z "${RESCATE_YES:-}" ] && [ -t 0 ]; }
msg()  { if have_tty; then whiptail --title "Rescate" --msgbox "$1" 20 76; else log "$(printf '%b' "$1")"; fi; }
ask()  { if have_tty; then whiptail --title "Rescate" --yesno "$1" 20 76; else log "(auto-sí) $1"; return 0; fi; }
input(){ whiptail --title "Rescate" --inputbox "$1" 10 70 "${2:-}" 3>&1 1>&2 2>&3; }
secret(){ whiptail --title "Rescate" --passwordbox "$1" 10 70 3>&1 1>&2 2>&3; }

ensure_efivars() {
  [ -d /sys/firmware/efi ] || return 1
  mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
  mount -o remount,rw /sys/firmware/efi/efivars 2>/dev/null
  return 0
}

# Etiquetas SELinux: el rescate corre sin SELinux, así que cada archivo que
# cambiemos en el sistema instalado se re-etiqueta con su política.
relabel() {  # relabel <ruta-dentro-del-sistema>...
  local fc="$DEP/etc/selinux/targeted/contexts/files/file_contexts"
  [ -f "$fc" ] || return 0
  chroot "$DEP" setfiles -F /etc/selinux/targeted/contexts/files/file_contexts "$@" >>"$LOG" 2>&1 || true
}

# ---------------------------------------------------------------- detección
# Rellena: DISK ROOTPART ROOTUUID ROOTSUBVOL BOOTPART BOOTUUID ESPPART ESPUUID ESPPARTUUID ESPNUM
detect() {
  DISK='' ROOTPART='' ROOTUUID='' ROOTSUBVOL='' BOOTPART='' BOOTUUID='' ESPPART='' ESPUUID='' ESPPARTUUID='' ESPNUM=''
  mkdir -p "$PROBE"
  local dev fs
  while read -r dev fs; do
    [ "$fs" = btrfs ] || continue
    mount -o ro,subvolid=5 "$dev" "$PROBE" 2>/dev/null || continue
    local d
    for d in "$PROBE"/*/ "$PROBE"/; do
      if [ -d "$d/ostree/deploy" ]; then
        ROOTPART=$dev
        ROOTSUBVOL=$(basename "$d"); [ "$d" = "$PROBE/" ] && ROOTSUBVOL=
        break
      fi
    done
    umount "$PROBE"
    [ -n "$ROOTPART" ] && break
  done < <(lsblk -lnpo NAME,FSTYPE)

  if [ -z "$ROOTPART" ]; then
    log "No se encontró ninguna instalación de Fedora Kinoite."
    return 1
  fi
  ROOTUUID=$(blkid -s UUID -o value "$ROOTPART")
  DISK=/dev/$(lsblk -no PKNAME "$ROOTPART" | head -1)

  while read -r dev fs ptype; do
    if [ "$ptype" = "$ESP_TYPE" ] && [ -z "$ESPPART" ]; then ESPPART=$dev; continue; fi
    if [ "$fs" = ext4 ] || [ "$fs" = xfs ]; then
      mount -o ro "$dev" "$PROBE" 2>/dev/null || continue
      if [ -d "$PROBE/loader" ] || [ -d "$PROBE/ostree" ] || [ -d "$PROBE/grub2" ]; then BOOTPART=$dev; fi
      umount "$PROBE"
    fi
  done < <(lsblk -lnpo NAME,FSTYPE,PARTTYPE "$DISK")

  [ -n "$ESPPART" ] && { ESPUUID=$(blkid -s UUID -o value "$ESPPART"); ESPPARTUUID=$(blkid -s PARTUUID -o value "$ESPPART"); ESPNUM=$(cat /sys/class/block/$(basename "$ESPPART")/partition); }
  [ -n "$BOOTPART" ] && BOOTUUID=$(blkid -s UUID -o value "$BOOTPART")
  log "Disco: $DISK | raíz: $ROOTPART (subvol '${ROOTSUBVOL:-/}') | /boot: ${BOOTPART:-NO ENCONTRADA} | EFI: ${ESPPART:-NO ENCONTRADA}"
  return 0
}

# ---------------------------------------------------------------- montaje
MOUNTS=()
domount() {  # domount <origen> <destino> [opciones]
  mkdir -p "$2"
  if mount ${3:+-o "$3"} "$1" "$2" >>"$LOG" 2>&1; then MOUNTS+=("$2"); return 0; fi
  return 1
}

mount_sysroot() {
  if mountpoint -q "$SYSROOT"; then
    [ ${#MOUNTS[@]} -gt 0 ] && return 0
    umount -R -l "$SYSROOT" 2>/dev/null   # restos de una ejecución anterior
  fi
  [ -n "$ROOTPART" ] || detect || return 1
  domount "$ROOTPART" "$SYSROOT" "${ROOTSUBVOL:+subvol=$ROOTSUBVOL}" || die "No se pudo montar la partición del sistema" || return 1
  [ -n "$BOOTPART" ] && { domount "$BOOTPART" "$SYSROOT/boot" || warn "No se pudo montar /boot"; }
  [ -n "$ESPPART" ]  && { domount "$ESPPART" "$SYSROOT/boot/efi" || warn "No se pudo montar la partición EFI"; }
  STATEROOT=$(ls "$SYSROOT/ostree/deploy" | head -1)
  find_default_deployment
  return 0
}

umount_all() {
  local i
  for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do umount -l "${MOUNTS[$i]}" 2>/dev/null; done
  MOUNTS=()
  sync
}

# Despliegue por defecto = el de la entrada BLS con número más alto
find_default_deployment() {
  DEP='' DEPENTRY=''
  local e best=-1 n
  for e in "$SYSROOT"/boot/loader/entries/ostree-*.conf; do
    [ -f "$e" ] || continue
    n=$(basename "$e" | sed -E 's/^ostree-([0-9]+).*/\1/')
    [[ $n =~ ^[0-9]+$ ]] || continue
    [ "$n" -gt "$best" ] && { best=$n; DEPENTRY=$e; }
  done
  if [ -n "$DEPENTRY" ]; then
    local op; op=$(grep -o 'ostree=[^ ]*' "$DEPENTRY" | cut -d= -f2)
    DEP=$(readlink -f "$SYSROOT$op" 2>/dev/null)
    case "$DEP" in "$SYSROOT"/ostree/deploy/*) ;; *) DEP=;; esac
  fi
  if [ -z "$DEP" ] || [ ! -d "$DEP/usr" ]; then
    # Sin entradas válidas: el despliegue más reciente del disco
    DEP=$(ls -dt "$SYSROOT"/ostree/deploy/"$STATEROOT"/deploy/*.[0-9] 2>/dev/null | head -1)
  fi
  [ -n "$DEP" ] && log "Sistema principal: $(basename "$DEP") ($(grep -s '^VERSION=' "$DEP/usr/lib/os-release" | cut -d= -f2))"
}

# Lista de despliegues "indice|checksum.serial|version|ruta"
list_deployments() {
  ostree admin --sysroot="$SYSROOT" status 2>/dev/null | awk -v sr="$STATEROOT" '
    $0 ~ "^[* ] +"sr" [0-9a-f]+\\.[0-9]+" { d=$0; sub(/^[* ]+[^ ]+ /,"",d); sub(/ .*/,"",d); i++; dep[i]=d; tag[i]=$0 }
    /Version:/ { v[i]=$2 }
    END { for (j=1;j<=i;j++) print j-1"|"dep[j]"|"v[j] }'
}

# Prepara el sistema instalado para chroot (con /var, /home, /boot, /dev...)
CHROOT_READY=
prepare_chroot() {
  [ -n "$CHROOT_READY" ] && return 0
  mount_sysroot || return 1
  [ -n "$DEP" ] || die "No hay ningún despliegue utilizable" || return 1
  domount "$SYSROOT" "$DEP/sysroot" rbind
  local src mp fs opts rest target l
  # Montar en orden de profundidad (/var antes que /var/home)
  while read -r _ target src opts; do
    domount "$(resolve_spec "$src")" "$target" "$opts" || log "  (no se montó $target, se continúa)"
  done < <(while read -r src mp fs opts rest; do
      case "$src" in ''|\#*) continue;; esac
      [ "$mp" = / ] || [ "$fs" = swap ] && continue
      case "$mp" in /boot|/boot/efi) continue;; esac
      target="$DEP$mp"
      if [ -L "$target" ]; then l=$(readlink "$target"); case "$l" in /*) target="$DEP$l";; *) target="$(dirname "$target")/$l";; esac; fi
      opts=$(echo "$opts" | sed -E 's/(^|,)(ro|x-[^,]*|nofail|noauto|defaults)(,|$)/\1/g; s/(^|,)(ro|x-[^,]*|nofail|noauto|defaults)(,|$)/\1/g; s/,+/,/g; s/^,|,$//g')
      echo "${#target} $target $src ${opts:-rw}"
    done < "$DEP/etc/fstab" | sort -n)
  # Si /var no es un subvolumen aparte, usar el /var del stateroot
  mountpoint -q "$DEP/var" || domount "$SYSROOT/ostree/deploy/$STATEROOT/var" "$DEP/var" bind
  domount "$SYSROOT/boot" "$DEP/boot" bind
  mountpoint -q "$SYSROOT/boot/efi" && domount "$SYSROOT/boot/efi" "$DEP/boot/efi" bind
  domount /dev "$DEP/dev" bind; domount /dev/pts "$DEP/dev/pts" bind
  mkdir -p "$DEP/proc"; mount -t proc proc "$DEP/proc" 2>/dev/null && MOUNTS+=("$DEP/proc")
  domount /sys "$DEP/sys" bind; domount /run "$DEP/run" bind
  cp -L /etc/resolv.conf "$DEP/run/rescate-resolv.conf" 2>/dev/null
  CHROOT_READY=1
}

resolve_spec() {
  case "$1" in
    UUID=*) blkid -U "${1#UUID=}" 2>/dev/null || echo "$1";;
    LABEL=*) blkid -L "${1#LABEL=}" 2>/dev/null || echo "$1";;
    PARTUUID=*) blkid -t "$1" -o device 2>/dev/null | head -1;;
    *) echo "$1";;
  esac
}

release_all() { umount_all; CHROOT_READY=; }

# ================================================================ REPARACIONES
# --- 1. Sistemas de archivos (sin montar) ---------------------------------
check_filesystems() {
  log "== Revisando sistemas de archivos =="
  release_all
  if [ -n "$ESPPART" ]; then
    fsck.vfat -a -w "$ESPPART" >>"$LOG" 2>&1; local r=$?
    [ $r -eq 0 ] && ok "Partición EFI sin errores" || fixd "Errores corregidos en la partición EFI (código $r)"
  fi
  if [ -n "$BOOTPART" ]; then
    e2fsck -f -y "$BOOTPART" >>"$LOG" 2>&1; local r=$?
    case $r in 0) ok "/boot sin errores";; 1|2) fixd "Errores corregidos en /boot";; *) warn "/boot tiene errores que no se pudieron corregir (código $r)";; esac
  fi
  if [ -n "$ROOTPART" ]; then
    log "  Revisando btrfs (puede tardar unos minutos)..."
    if btrfs check --readonly --progress "$ROOTPART" >>"$LOG" 2>&1; then
      ok "Sistema btrfs sin errores"
    else
      warn "btrfs reporta errores. Se intentará montar y reparar con 'scrub'."
      # Intento seguro: borrar el registro de transacciones si impide montar
      if ! mount -o ro "$ROOTPART" "$PROBE" 2>/dev/null; then
        run btrfs rescue zero-log "$ROOTPART" && fixd "Registro btrfs dañado limpiado (zero-log)"
      else umount "$PROBE"; fi
    fi
  fi
}

scrub_btrfs() {
  mount_sysroot || return 1
  log "  Verificando y reparando datos de btrfs (scrub)..."
  if btrfs scrub start -B "$SYSROOT" >>"$LOG" 2>&1; then ok "Scrub de btrfs completado"; else warn "Scrub encontró errores incorregibles (revisa el registro)"; fi
}

# --- 2. Espacio ------------------------------------------------------------
check_space() {
  log "== Revisando espacio libre =="
  mount_sysroot || return 1
  local bootpct; bootpct=$(df --output=pcent "$SYSROOT/boot" | tail -1 | tr -dc 0-9)
  if [ "${bootpct:-0}" -ge 85 ]; then
    run ostree admin --sysroot="$SYSROOT" cleanup
    fixd "Limpieza de /boot (estaba al ${bootpct}%)"
  else ok "/boot al ${bootpct}%"; fi
  local free; free=$(btrfs filesystem usage -b "$SYSROOT" 2>/dev/null | awk '/Free \(estimated\)/{print $3}')
  if [ -n "$free" ] && [ "$free" -lt 5368709120 ]; then
    run ostree admin --sysroot="$SYSROOT" cleanup
    run btrfs balance start -dusage=10 "$SYSROOT"
    fixd "Disco casi lleno: se limpiaron versiones viejas y se compactó btrfs"
  else ok "Espacio en disco suficiente"; fi
}

# --- 3. Partición EFI (shim/grub) -------------------------------------------
# Busca un archivo de arranque (p.ej. fedora/grubx64.efi) en el sistema
# instalado; si no está, usa el que trae el propio Rescate.
efi_file() {
  local f=$1 c
  for c in "$DEP/usr/lib/ostree-boot/efi/EFI/$f" \
           $(ls -d "$DEP"/usr/lib/efi/*/*/EFI/"$f" 2>/dev/null | sort -V -r) \
           $(ls -d /usr/lib/efi/*/*/EFI/"$f" 2>/dev/null | sort -V -r) \
           "/boot/efi/EFI/$f"; do
    [ -s "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

repair_efi_files() {
  log "== Revisando archivos de arranque EFI =="
  mount_sysroot || return 1
  mountpoint -q "$SYSROOT/boot/efi" || { warn "Partición EFI no disponible"; return 1; }
  local E="$SYSROOT/boot/efi/EFI" changed='' missing='' f src
  mkdir -p "$E/fedora" "$E/BOOT"
  for f in fedora/shimx64.efi fedora/grubx64.efi fedora/mmx64.efi fedora/BOOTX64.CSV BOOT/BOOTX64.EFI BOOT/fbx64.efi; do
    src=$(efi_file "$f")
    [ -z "$src" ] && [ "$f" = BOOT/BOOTX64.EFI ] && src=$(efi_file fedora/shimx64.efi)
    [ -n "$src" ] || { missing+=" $f"; continue; }
    if ! cmp -s "$src" "$E/$f"; then cp -f "$src" "$E/$f" && changed+=" $f"; fi
  done
  [ -n "$missing" ] && warn "No se encontró copia de:$missing"
  [ -n "$changed" ] && fixd "Cargadores EFI restaurados:$changed" || ok "Cargadores EFI correctos"
  sync
  write_esp_grubcfg
}

write_esp_grubcfg() {
  local E="$SYSROOT/boot/efi/EFI/fedora" want tmp
  tmp=$(mktemp)
  local static="$DEP/usr/lib/bootupd/grub2-static/grub-static-efi.cfg"
  if [ -f "$static" ]; then
    cp "$static" "$tmp"
    printf 'set BOOT_UUID="%s"\n' "$BOOTUUID" > "$tmp.uuid"
    if ! cmp -s "$tmp" "$E/grub.cfg" || ! cmp -s "$tmp.uuid" "$E/bootuuid.cfg"; then
      cp "$tmp" "$E/grub.cfg"; cp "$tmp.uuid" "$E/bootuuid.cfg"; fixd "grub.cfg de la partición EFI reescrito"
    else ok "grub.cfg de la partición EFI correcto"; fi
  else
    if ! grep -qs "$BOOTUUID" "$E/grub.cfg"; then
      cat > "$E/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=dev $BOOTUUID
set prefix=(\$dev)/grub2
export \$prefix
configfile \$prefix/grub.cfg
EOF
      fixd "grub.cfg de la partición EFI reescrito"
    else ok "grub.cfg de la partición EFI correcto"; fi
  fi
  rm -f "$tmp" "$tmp.uuid"
}

# --- 4. GRUB en /boot -------------------------------------------------------
repair_grub_config() {
  log "== Revisando configuración de GRUB =="
  mount_sysroot || return 1
  local G="$SYSROOT/boot/grub2"; mkdir -p "$G"
  local S="$DEP/usr/lib/bootupd/grub2-static"
  if [ ! -s "$G/grub.cfg" ] || ! grep -q blscfg "$G/grub.cfg"; then
    if [ -f "$S/grub-static-pre.cfg" ]; then
      cat "$S/grub-static-pre.cfg" "$S"/configs.d/*.cfg > "$G/grub.cfg"
    else
      cat > "$G/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $BOOTUUID
set boot=\$root
if [ -s \$prefix/grubenv ]; then load_env; fi
set timeout=5
set timeout_style=menu
insmod all_video
blscfg
if [ -f \$prefix/custom.cfg ]; then source \$prefix/custom.cfg; fi
EOF
    fi
    fixd "Configuración principal de GRUB regenerada"
  else ok "Configuración principal de GRUB correcta"; fi
  [ -f "$S/grub-static-pre.cfg" ] && printf 'set BOOT_UUID="%s"\n' "$BOOTUUID" > "$G/bootuuid.cfg"
  if [ ! -f "$G/grubenv" ] || [ "$(stat -c %s "$G/grubenv")" != 1024 ]; then
    rm -f "$G/grubenv"; grub2-editenv "$G/grubenv" create; fixd "grubenv recreado"
  fi
  # Que el menú siempre se vea 5 s (para poder elegir Rescate)
  grub2-editenv "$G/grubenv" unset menu_auto_hide 2>/dev/null
  grub2-editenv "$G/grubenv" unset boot_success 2>/dev/null
  write_rescate_entry
}

write_rescate_entry() {
  [ -f "$SYSROOT/boot/rescate/vmlinuz" ] || install_rescate_files
  # Copia de emergencia en btrfs (por si /boot se daña)
  if mount -o subvolid=5 "$ROOTPART" "$PROBE" 2>/dev/null; then
    if [ -f "$SYSROOT/boot/rescate/rootfs.img" ] && ! cmp -s "$SYSROOT/boot/rescate/rootfs.img" "$PROBE/rescate/rootfs.img"; then
      mkdir -p "$PROBE/rescate"; cp "$SYSROOT"/boot/rescate/{vmlinuz,initramfs.img,rootfs.img} "$PROBE/rescate/" && fixd "Copia de emergencia de Rescate actualizada"
    fi
    umount "$PROBE"
  fi
  if /usr/local/sbin/rescate-grub "$SYSROOT/boot" >>"$LOG" 2>&1; then ok "Entradas de Rescate y modo seguro presentes en GRUB"
  else warn "No se pudieron escribir las entradas de Rescate en GRUB"; fi
  install_host_hook
}

# Instala en el Fedora del disco el servicio que mantiene GRUB al día
install_host_hook() {
  [ -n "$DEP" ] || return
  local E="$DEP/etc"
  mkdir -p "$E/rescate" "$E/systemd/system/multi-user.target.wants" "$E/systemd/system/ostree-finalize-staged.service.d"
  install -m 0755 /usr/local/sbin/rescate-grub "$E/rescate/rescate-grub"
  cat > "$E/systemd/system/rescate-grub.service" <<'X'
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
  cat > "$E/systemd/system/ostree-finalize-staged.service.d/rescate.conf" <<'X'
[Service]
ExecStop=-/etc/rescate/rescate-grub /boot
X
  ln -sf ../rescate-grub.service "$E/systemd/system/multi-user.target.wants/rescate-grub.service"
  prepare_chroot && relabel /etc/rescate /etc/systemd/system/rescate-grub.service /etc/systemd/system/ostree-finalize-staged.service.d /etc/systemd/system/multi-user.target.wants
}

# Copia el propio Rescate a /boot/rescate (tras una reinstalación o si falta)
install_rescate_files() {
  local src=/usr/local/share/rescate
  [ -f "$src/vmlinuz" ] || { warn "No se encontraron los archivos del Rescate para reinstalarlo"; return 1; }
  local sq; sq=$(ls /run/initramfs/squashed.img /run/initramfs/live/rescate/rootfs.img 2>/dev/null | head -1)
  [ -n "$sq" ] || { warn "No se encontró la imagen del Rescate en memoria"; return 1; }
  mkdir -p "$SYSROOT/boot/rescate"
  cp "$src/vmlinuz" "$src/initramfs.img" "$SYSROOT/boot/rescate/" && cp "$sq" "$SYSROOT/boot/rescate/rootfs.img" \
    && fixd "Rescate reinstalado en /boot/rescate"
  [ -f "$src/memtest.efi" ] && cp "$src/memtest.efi" "$SYSROOT/boot/rescate/"
}

# --- 5. Entradas de arranque (BLS) ------------------------------------------
repair_boot_entries() {
  log "== Revisando entradas de arranque de Fedora =="
  mount_sysroot || return 1
  local e bad=0 good=0
  for e in "$SYSROOT"/boot/loader/entries/ostree-*.conf; do
    [ -f "$e" ] || continue
    local k i o
    k=$(awk '$1=="linux"{print $2}' "$e"); i=$(awk '$1=="initrd"{print $2}' "$e")
    o=$(grep -o 'ostree=[^ ]*' "$e" | cut -d= -f2)
    if [ -s "$SYSROOT/boot$k" ] && [ -s "$SYSROOT/boot$i" ] && [ -d "$(readlink -f "$SYSROOT$o")/usr" ]; then
      good=$((good+1))
      # root=UUID debe apuntar a la partición correcta
      if ! grep -q "root=UUID=$ROOTUUID" "$e"; then
        sed -i -E "s/root=UUID=[^ ]+/root=UUID=$ROOTUUID/" "$e"; fixd "UUID de raíz corregido en $(basename "$e")"
      fi
    else bad=$((bad+1)); log "  entrada rota: $(basename "$e")"; fi
  done
  if [ $bad -gt 0 ] || [ $good -eq 0 ]; then
    redeploy_default && fixd "Entradas de arranque regeneradas"
  else ok "$good entradas de arranque válidas"; fi
}

# Deja solo 2 versiones (la actual y una anterior) para no llenar /boot
prune_deployments() {
  local n; n=$(list_deployments | wc -l)
  while [ "$n" -gt 2 ]; do
    run ostree admin --sysroot="$SYSROOT" undeploy $((n-1)) || break
    n=$((n-1))
  done
}

# Vuelve a desplegar el commit principal: regenera kernel, initramfs y entradas
redeploy_default() {
  [ -n "$DEP" ] || return 1
  local base csum
  base=$(basename "$DEP"); csum=${base%.*}
  log "  Regenerando el despliegue $csum..."
  local args=(--sysroot="$SYSROOT" --os="$STATEROOT" --retain-rollback)
  [ -f "$DEP.origin" ] && args+=(--origin-file="$DEP.origin")
  if ! grep -qs . "$SYSROOT"/boot/loader/entries/*.conf; then
    args+=(--karg-none --karg="root=UUID=$ROOTUUID" --karg=rw --karg=rhgb --karg=quiet)
    [ -n "$ROOTSUBVOL" ] && args+=(--karg="rootflags=subvol=$ROOTSUBVOL")
    nvidia_layered && for k in $NVIDIA_KARGS; do args+=(--karg-append="$k"); done
  fi
  run ostree admin deploy "${args[@]}" "$csum" || { warn "No se pudo regenerar el despliegue"; return 1; }
  prune_deployments
  CHROOT_READY=; find_default_deployment
}

# --- 6. Entrada UEFI del firmware -------------------------------------------
repair_uefi_entries() {
  log "== Revisando el menú de arranque UEFI del equipo =="
  ensure_efivars || { warn "El equipo no arrancó en modo UEFI"; return 1; }
  [ -n "$ESPPART" ] || { warn "Sin partición EFI"; return 1; }
  local parts; parts=$(lsblk -lno PARTUUID | tr 'A-Z' 'a-z')
  local line num pu
  # Borrar entradas que apuntan a particiones que ya no existen
  while read -r line; do
    num=$(echo "$line" | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
    pu=$(echo "$line" | grep -oiE 'GPT,[0-9a-f-]{36}' | cut -d, -f2 | tr 'A-Z' 'a-z')
    if [ -n "$pu" ] && echo "$line" | grep -q '\\EFI\\' && ! grep -qx "$pu" <<<"$parts"; then
      run efibootmgr -b "$num" -B && fixd "Entrada UEFI inválida eliminada: $(echo "$line" | cut -c10- | cut -f1)"
    fi
  done < <(efibootmgr -v 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}')
  # Asegurar la entrada Fedora -> shim
  local fed
  fed=$(efibootmgr -v | grep -i "$ESPPARTUUID" | grep -i 'fedora\\shimx64.efi' | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
  if [ -z "$fed" ]; then
    run efibootmgr -c -d "$DISK" -p "$ESPNUM" -L Fedora -l '\EFI\fedora\shimx64.efi'
    fed=$(efibootmgr -v | grep -i 'fedora\\shimx64.efi' | grep -i "$ESPPARTUUID" | head -1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')
    fixd "Entrada UEFI 'Fedora' creada"
  else ok "Entrada UEFI 'Fedora' presente (Boot$fed)"; fi
  # Fedora primero en el orden de arranque
  local order; order=$(efibootmgr | awk -F': ' '/^BootOrder/{print $2}')
  if [ -n "$fed" ] && [ "${order%%,*}" != "$fed" ]; then
    local rest; rest=$(echo "$order" | tr ',' '\n' | grep -vx "$fed" | paste -sd,)
    run efibootmgr -o "$fed${rest:+,$rest}" && fixd "Fedora puesto primero en el orden de arranque"
  fi
  efibootmgr -N >/dev/null 2>&1   # quitar un BootNext pendiente
}

# --- 7. fstab ---------------------------------------------------------------
repair_fstab() {
  log "== Revisando /etc/fstab =="
  mount_sysroot || return 1
  local F="$DEP/etc/fstab" tmp changed=0
  [ -f "$F" ] || { write_fstab "$F"; fixd "fstab no existía: creado"; return; }
  tmp=$(mktemp)
  while IFS= read -r line; do
    set -- $line
    case "$1" in ''|\#*) echo "$line" >>"$tmp"; continue;; esac
    local spec=$1 mp=$2 fs=$3 opts=$4 dev
    dev=$(resolve_spec "$spec")
    if [ -b "$dev" ]; then echo "$line" >>"$tmp"; continue; fi
    case "$mp" in
      /|/var|/home|/var/home)  line=$(echo "$line" | sed "s|^$spec|UUID=$ROOTUUID|"); changed=1;;
      /boot)     line=$(echo "$line" | sed "s|^$spec|UUID=$BOOTUUID|"); changed=1;;
      /boot/efi) line=$(echo "$line" | sed "s|^$spec|UUID=$ESPUUID|"); changed=1;;
      *) if [[ ",$opts," != *,nofail,* ]]; then
           line=$(echo "$line" | awk -v o="$opts,nofail,x-systemd.device-timeout=5s" '{$4=o; print}'); changed=1
           warn "Disco no encontrado para $mp: marcado como opcional (nofail)"
         fi;;
    esac
    echo "$line" >>"$tmp"
  done < "$F"
  if [ $changed = 1 ]; then cp "$F" "$F.rescate.bak"; cat "$tmp" > "$F"; fixd "fstab corregido (copia en fstab.rescate.bak)"; else ok "fstab correcto"; fi
  rm -f "$tmp"
}

write_fstab() {
  local subopt=""; [ -n "$ROOTSUBVOL" ] && subopt="subvol=$ROOTSUBVOL,"
  {
    echo "UUID=$ROOTUUID / btrfs ${subopt}compress=zstd:1,ro 0 0"
    echo "UUID=$BOOTUUID /boot ext4 defaults 1 2"
    echo "UUID=$ESPUUID /boot/efi vfat umask=0077,shortname=winnt 0 2"
    has_subvol home && echo "UUID=$ROOTUUID /home btrfs subvol=home,compress=zstd:1 0 0"
    has_subvol var  && echo "UUID=$ROOTUUID /var btrfs subvol=var,compress=zstd:1 0 0"
  } > "$1"
}

has_subvol() { btrfs subvolume list "$SYSROOT" 2>/dev/null | awk '{print $NF}' | grep -qx "$1"; }

# --- 8. NVIDIA --------------------------------------------------------------
nvidia_layered() { grep -qs 'akmod-nvidia\|kmod-nvidia' "${DEP:-/nonexistent}.origin"; }
nvidia_module_in() {  # $1 = ruta del despliegue
  local m; for m in "$1"/usr/lib/modules/*/; do
    find "$m" -name 'nvidia.ko*' -print -quit 2>/dev/null | grep -q . && return 0
  done; return 1
}
entry_has() { grep -q "^options.* $1\( \|$\)" "$DEPENTRY"; }
entry_add() { [ -f "$DEPENTRY" ] || return 1; local k; for k in "$@"; do entry_has "$k" || sed -i -E "/^options /s|\$| $k|" "$DEPENTRY"; done; }
entry_del() { [ -f "$DEPENTRY" ] || return 1; local k; for k in "$@"; do sed -i -E "/^options /{s/ $(printf '%s' "$k" | sed 's/[.[\*^$/]/\\&/g')( |$)/\1/g}" "$DEPENTRY"; done; }

check_nvidia() {
  log "== Revisando el controlador NVIDIA =="
  mount_sysroot || return 1
  lspci -d 10de: 2>/dev/null | grep -qiE 'vga|3d' || { ok "No hay tarjeta NVIDIA"; return 0; }
  if ! nvidia_layered; then ok "El controlador NVIDIA no está instalado (se usa el libre)"; return 0; fi
  [ -n "$DEPENTRY" ] && entry_has nomodeset && { entry_del nomodeset; fixd "Quitado 'nomodeset' (rompe el controlador NVIDIA)"; }
  if nvidia_module_in "$DEP"; then
    ok "Módulo NVIDIA presente para el kernel actual"
    if [ -n "$DEPENTRY" ] && ! entry_has nvidia-drm.modeset=1; then entry_add $NVIDIA_KARGS; fixd "Parámetros NVIDIA restaurados"; fi
    return 0
  fi
  warn "El módulo NVIDIA NO se compiló para el kernel de la versión actual"
  # Buscar una versión anterior que sí lo tenga
  local idx d v
  while IFS='|' read -r idx d v; do
    [ "$idx" = 0 ] && continue
    if nvidia_module_in "$SYSROOT/ostree/deploy/$STATEROOT/deploy/$d"; then
      run ostree admin --sysroot="$SYSROOT" set-default "$idx" && {
        fixd "Arranque cambiado a la versión $v (tiene NVIDIA funcionando)"
        CHROOT_READY=; find_default_deployment; schedule_nvidia_rebuild; return 0; }
    fi
  done < <(list_deployments)
  # Ninguna versión lo tiene: arrancar con la gráfica Intel y reconstruir al iniciar
  entry_add $INTEL_ONLY_KARGS
  fixd "Arranque temporal solo con gráfica Intel (NVIDIA desactivada)"
  schedule_nvidia_rebuild
}

# Servicio de un solo uso: al arrancar con internet reconstruye el driver
schedule_nvidia_rebuild() {
  local U="$DEP/etc/systemd/system"
  mkdir -p "$U/multi-user.target.wants"
  cat > "$U/rescate-nvidia.service" <<EOF
[Unit]
Description=Rescate: reconstruir el controlador NVIDIA
Wants=network-online.target
After=network-online.target rpm-ostreed.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rpm-ostree cleanup -m; rpm-ostree upgrade || rpm-ostree upgrade --bypass-driver; rpm-ostree kargs --delete-if-present=rd.driver.blacklist=nvidia --delete-if-present=modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm --append-if-missing=rd.driver.blacklist=nouveau --append-if-missing=modprobe.blacklist=nouveau --append-if-missing=nvidia-drm.modeset=1'
ExecStartPost=/bin/rm -f /etc/systemd/system/rescate-nvidia.service /etc/systemd/system/multi-user.target.wants/rescate-nvidia.service
ExecStartPost=/bin/sh -c 'wall "Rescate: controlador NVIDIA reconstruido. Reinicia el equipo para usarlo."'

[Install]
WantedBy=multi-user.target
EOF
  ln -sf ../rescate-nvidia.service "$U/multi-user.target.wants/rescate-nvidia.service"
  prepare_chroot && relabel /etc/systemd/system/rescate-nvidia.service /etc/systemd/system/multi-user.target.wants
  fixd "Programado: reconstruir NVIDIA automáticamente en el próximo arranque con internet"
}

# Todo lo escrito en /boot desde el Rescate queda sin etiqueta SELinux;
# Fedora lo necesita etiquetado (si no, sus servicios no pueden leerlo).
fix_boot_labels() {
  prepare_chroot || return 1
  relabel /boot /etc/rescate /etc/systemd/system
  ok "Etiquetas SELinux de /boot correctas"
}

# --- 9. SELinux -------------------------------------------------------------
repair_selinux() {
  log "== Reparando etiquetas SELinux (/etc y /var) =="
  prepare_chroot || return 1
  chroot "$DEP" setfiles -F -e /var/home -e /var/lib/containers /etc/selinux/targeted/contexts/files/file_contexts /etc /var >>"$LOG" 2>&1
  chroot "$DEP" setfiles -F /etc/selinux/targeted/contexts/files/file_contexts /var/home >>"$LOG" 2>&1
  fixd "Etiquetas SELinux restauradas"
}

# --- 10. Diagnóstico de discos ----------------------------------------------
disk_health() {
  log "== Salud del disco =="
  local d=${DISK:-/dev/nvme0n1}
  if smartctl -H "$d" >>"$LOG" 2>&1; then ok "Disco $d: salud correcta (SMART)"
  else warn "SMART indica problemas en $d: haz copia de seguridad cuanto antes"; fi
}

# --- 11. Errores del último arranque ----------------------------------------
last_boot_errors() {
  prepare_chroot || return 1
  local J="$DEP/var/log/journal"
  [ -d "$J" ] || { echo "No hay registros guardados."; return; }
  journalctl -D "$J" -b -1 -p err --no-pager -o short 2>/dev/null | tail -n 200 ||
  journalctl -D "$J" -b 0 -p err --no-pager 2>/dev/null | tail -n 200
}

# ================================================================ REPARACIÓN AUTOMÁTICA
auto_repair() {
  FIXES=(); WARNINGS=()
  log "################ REPARACIÓN AUTOMÁTICA $(date) ################"
  detect || { msg "No se encontró Fedora Kinoite en ningún disco.\n\nPuedes usar 'Reinstalar Fedora Kinoite' desde cero."; return 1; }
  check_filesystems
  mount_sysroot || { msg "No se pudo montar el sistema. Revisa el registro."; return 1; }
  check_space
  repair_boot_entries
  repair_efi_files
  repair_grub_config
  repair_uefi_entries
  repair_fstab
  check_nvidia
  fix_boot_labels
  disk_health
  release_all
  sync
  local s="Reparación terminada.\n\n"
  if [ ${#FIXES[@]} -gt 0 ]; then s+="Se arregló:\n"; for f in "${FIXES[@]}"; do s+=" • $f\n"; done
  else s+="No se encontró nada roto en el arranque.\n"; fi
  if [ ${#WARNINGS[@]} -gt 0 ]; then s+="\nAvisos:\n"; for f in "${WARNINGS[@]}"; do s+=" • $f\n"; done; fi
  s+="\nSi Fedora sigue sin arrancar, prueba 'Volver a una versión anterior' o 'Reinstalar Fedora Kinoite (conservando datos)'."
  msg "$s"
}

# ================================================================ VERSIONES
rollback_menu() {
  mount_sysroot || return 1
  local items=() idx d v
  while IFS='|' read -r idx d v; do
    local tag=""; [ "$idx" = 0 ] && tag=" (actual)"
    nvidia_layered && { nvidia_module_in "$SYSROOT/ostree/deploy/$STATEROOT/deploy/$d" && tag+=" NVIDIA✔" || tag+=" NVIDIA✖"; }
    items+=("$idx" "Fedora $v$tag")
  done < <(list_deployments)
  [ ${#items[@]} -gt 2 ] || { msg "Solo hay una versión instalada. No hay a cuál volver."; return; }
  local c; c=$(whiptail --title "Rescate" --menu "¿Con qué versión quieres arrancar?" 16 70 6 "${items[@]}" 3>&1 1>&2 2>&3) || return
  [ "$c" = 0 ] && return
  run ostree admin --sysroot="$SYSROOT" set-default "$c" && msg "Listo. Al reiniciar arrancará esa versión.\n\nCuando quieras actualizar de nuevo usa: rpm-ostree upgrade"
  release_all
}

# ================================================================ REINSTALAR
copy_remote_config() {
  mkdir -p /etc/ostree/remotes.d
  if [ -n "$DEP" ] && ls "$DEP"/etc/ostree/remotes.d/*.conf >/dev/null 2>&1; then
    cp "$DEP"/etc/ostree/remotes.d/*.conf /etc/ostree/remotes.d/
  fi
  [ -f /etc/ostree/remotes.d/fedora.conf ] || cp /usr/local/share/rescate/fedora.conf /etc/ostree/remotes.d/
}

# Descarga Fedora Kinoite al repositorio del disco y deja la referencia
# "fedora:<rama>" lista para desplegar. Firma GPG verificada.
pull_kinoite() {  # pull_kinoite <rama>
  local R="$SYSROOT/ostree/repo" branch=$1
  ostree remote delete --repo="$R" --if-exists rescate-fedora 2>/dev/null
  ostree remote add --repo="$R" --set=gpg-verify=true --set=gpgkeypath=/etc/pki/rpm-gpg/ \
    --set=contenturl=mirrorlist=https://ostree.fedoraproject.org/mirrorlist \
    rescate-fedora https://ostree.fedoraproject.org || return 1
  log "  Descargando Fedora Kinoite ($branch). Puede tardar bastante..."
  local okp=0
  for try in 1 2 3; do
    if ostree pull --repo="$R" rescate-fedora "$branch" 2>&1 | tee -a "$LOG" >&2; then okp=1; break; fi
    log "  Reintentando descarga ($try)..."; sleep 5
  done
  local csum; csum=$(ostree rev-parse --repo="$R" "rescate-fedora:$branch" 2>/dev/null)
  ostree remote delete --repo="$R" rescate-fedora 2>/dev/null
  [ $okp = 1 ] && [ -n "$csum" ] || return 1
  ostree refs --repo="$R" --delete "rescate-fedora:$branch" 2>/dev/null
  ostree refs --repo="$R" --create="fedora:$branch" "$csum" --force >>"$LOG" 2>&1 || \
    { ostree refs --repo="$R" --delete "fedora:$branch" 2>/dev/null; ostree refs --repo="$R" --create="fedora:$branch" "$csum"; }
  echo "$csum"
}

need_internet() {
  curl -s -m 10 -o /dev/null https://ostree.fedoraproject.org/ && return 0
  msg "Se necesita internet para descargar Fedora Kinoite.\n\nConéctate primero (opción 'Conectar a internet')."
  return 1
}

# Reinstala el sistema operativo sin tocar /home ni /var
reinstall_keep() {
  local reset_etc=${1:-no}
  detect && mount_sysroot || { msg "No hay sistema instalado. Usa la reinstalación desde cero."; return 1; }
  need_internet || return 1
  copy_remote_config
  local ref
  ref=$(grep -hE '^(baserefspec|refspec)=' "$DEP.origin" 2>/dev/null | head -1 | cut -d= -f2)
  [ -n "$ref" ] || ref="fedora:fedora/$FEDORA_VER/x86_64/kinoite"
  local remote=${ref%%:*} branch=${ref#*:}
  log "== Reinstalando $ref (se conservan tus archivos) =="
  local csum; csum=$(pull_kinoite "$branch" | tail -1) && [ -n "$csum" ] || { msg "No se pudo descargar Fedora Kinoite. Revisa la conexión."; return 1; }
  ref="fedora:$branch"
  local origin=/tmp/rescate.origin
  printf '[origin]\nrefspec=%s\n' "$ref" > "$origin"
  run ostree admin deploy --sysroot="$SYSROOT" --os="$STATEROOT" --retain-rollback --origin-file="$origin" "$csum" \
    || { msg "Falló la instalación. Revisa $LOG"; return 1; }
  prune_deployments
  local oldpkgs; oldpkgs=$(grep -h '^packages=' "$DEP.origin" 2>/dev/null | cut -d= -f2)
  local oldlocal; oldlocal=$(grep -h '^localpackages=' "$DEP.origin" 2>/dev/null)
  local olddep=$DEP
  CHROOT_READY=; find_default_deployment
  if [ "$reset_etc" = yes ]; then reset_etc_to_defaults "$olddep"; fi
  # Restaurar NVIDIA y demás paquetes en el primer arranque, si el usuario quiere
  if [ -n "$oldpkgs" ] && ask "Tenías estos paquetes añadidos:\n\n$(echo "$oldpkgs" | tr ';' ' ' | fold -s -w 70)\n\n¿Reinstalarlos automáticamente en el primer arranque? (incluye NVIDIA)"; then
    schedule_layered_restore "$oldpkgs" "$oldlocal"
  else
    entry_del $NVIDIA_KARGS   # sin el driver privativo, que funcione el libre
  fi
  write_rescate_entry; repair_efi_files; repair_uefi_entries; fix_boot_labels
  release_all
  msg "Fedora Kinoite reinstalado.\n\nTus archivos personales se conservaron. La versión anterior queda disponible en el menú de GRUB por si acaso.\n\nReinicia el equipo."
}

schedule_layered_restore() {
  local pkgs; pkgs=$(echo "$1" | tr ';' ' ')
  local urls=""
  if echo "$2 $pkgs" | grep -q rpmfusion; then
    urls="https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$FEDORA_VER.noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$FEDORA_VER.noarch.rpm"
  fi
  local U="$DEP/etc/systemd/system"; mkdir -p "$U/multi-user.target.wants"
  cat > "$U/rescate-paquetes.service" <<EOF
[Unit]
Description=Rescate: reinstalar paquetes añadidos
Wants=network-online.target
After=network-online.target rpm-ostreed.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '${urls:+rpm-ostree install --idempotent --apply-live $urls; }rpm-ostree install --idempotent --allow-inactive $pkgs'
ExecStartPost=/bin/rm -f /etc/systemd/system/rescate-paquetes.service /etc/systemd/system/multi-user.target.wants/rescate-paquetes.service
ExecStartPost=/bin/sh -c 'wall "Rescate: paquetes reinstalados. Reinicia el equipo para usarlos."'

[Install]
WantedBy=multi-user.target
EOF
  ln -sf ../rescate-paquetes.service "$U/multi-user.target.wants/rescate-paquetes.service"
  prepare_chroot && relabel /etc/systemd/system/rescate-paquetes.service /etc/systemd/system/multi-user.target.wants
  fixd "Paquetes añadidos se reinstalarán solos en el primer arranque"
}

# Configuración de fábrica conservando usuarios, red, discos e idioma
reset_etc_to_defaults() {
  local old=$1 E="$DEP/etc" keep
  local tmp=/tmp/rescate-etc-keep; rm -rf "$tmp"; mkdir -p "$tmp"
  for keep in passwd shadow group gshadow subuid subgid fstab hostname locale.conf vconsole.conf machine-id localtime \
              NetworkManager/system-connections ostree/remotes.d sudoers.d crypttab plasma-setup-done; do
    [ -e "$old/etc/$keep" ] && { mkdir -p "$tmp/$(dirname "$keep")"; cp -a "$old/etc/$keep" "$tmp/$keep"; }
  done
  rm -rf "$E"; cp -a "$DEP/usr/etc" "$E"
  cp -a "$tmp/." "$E/"
  prepare_chroot && relabel /etc
  fixd "Configuración del sistema restablecida de fábrica (usuarios, red y discos conservados)"
}

# Borra el disco entero e instala Fedora Kinoite limpio
reinstall_full() {
  local disk=$1 user=$2 pass=$3 host=${4:-fedora} fullname=${5:-$2}
  [ -b "$disk" ] || { msg "Disco no válido: $disk"; return 1; }
  need_internet || return 1
  release_all
  log "################ REINSTALACIÓN COMPLETA en $disk ################"
  swapoff -a 2>/dev/null
  # Desmontar cualquier cosa que quede montada del disco (intentos anteriores)
  umount -R "$SYSROOT" 2>/dev/null; umount -R "$PROBE" 2>/dev/null
  local part; for part in $(lsblk -lnpo NAME "$disk" | tail -n +2); do umount -A -l "$part" 2>/dev/null; done
  run wipefs -af "$disk"; run sgdisk --zap-all "$disk"
  run sgdisk -n1:0:+600M -t1:EF00 -c1:"EFI System Partition" -n2:0:+2G -t2:8300 -c2:boot -n3:0:0 -t3:8304 -c3:fedora "$disk" \
    || { msg "No se pudo particionar $disk"; return 1; }
  partprobe "$disk"; udevadm settle; sleep 2
  local p=$disk; [[ $disk =~ [0-9]$ ]] && p=${disk}p
  run mkfs.vfat -F32 -n EFI "${p}1" && run mkfs.ext4 -F -L boot "${p}2" && run mkfs.btrfs -f -L fedora "${p}3" \
    || { msg "No se pudieron formatear las particiones"; return 1; }
  udevadm settle
  domount "${p}3" "$PROBE"
  run btrfs subvolume create "$PROBE/root"; run btrfs subvolume create "$PROBE/home"; run btrfs subvolume create "$PROBE/var"
  umount "$PROBE"; MOUNTS=()
  DISK=$disk ESPPART=${p}1 BOOTPART=${p}2 ROOTPART=${p}3 ROOTSUBVOL=root ESPNUM=1
  ROOTUUID=$(blkid -s UUID -o value "$ROOTPART"); BOOTUUID=$(blkid -s UUID -o value "$BOOTPART")
  ESPUUID=$(blkid -s UUID -o value "$ESPPART"); ESPPARTUUID=$(blkid -s PARTUUID -o value "$ESPPART")
  domount "$ROOTPART" "$SYSROOT" "subvol=root,compress=zstd:1"
  domount "$BOOTPART" "$SYSROOT/boot"
  domount "$ESPPART" "$SYSROOT/boot/efi" "umask=0077"
  STATEROOT=fedora
  run ostree admin init-fs --modern "$SYSROOT"
  run ostree admin os-init "$STATEROOT" --sysroot="$SYSROOT"
  run ostree config --repo="$SYSROOT/ostree/repo" set sysroot.bootloader none
  run ostree config --repo="$SYSROOT/ostree/repo" set sysroot.readonly true
  DEP=; copy_remote_config
  local ref="fedora:fedora/$FEDORA_VER/x86_64/kinoite"
  pull_kinoite "fedora/$FEDORA_VER/x86_64/kinoite" >/dev/null \
    || { msg "Falló la descarga. Revisa la conexión y vuelve a intentar."; return 1; }
  # /var del stateroot = subvolumen var (como en la instalación original)
  domount "$ROOTPART" "$SYSROOT/ostree/deploy/$STATEROOT/var" "subvol=var"
  run ostree admin deploy --sysroot="$SYSROOT" --os="$STATEROOT" \
     --karg="root=UUID=$ROOTUUID" --karg="rootflags=subvol=root" --karg=rw --karg=rhgb --karg=quiet \
     --karg="vconsole.keymap=latam" "$ref" || { msg "Falló la instalación. Revisa $LOG"; return 1; }
  find_default_deployment
  write_fstab "$DEP/etc/fstab"
  echo "$host" > "$DEP/etc/hostname"
  printf 'KEYMAP=latam\nFONT=eurlatgr\nXKBLAYOUT=latam\nXKBMODEL=pc105\n' > "$DEP/etc/vconsole.conf"
  echo 'LANG=es_ES.UTF-8' > "$DEP/etc/locale.conf"
  ln -sf ../usr/share/zoneinfo/America/Mexico_City "$DEP/etc/localtime"
  [ -f /etc/localtime ] && ln -sf "$(readlink /etc/localtime)" "$DEP/etc/localtime"
  prepare_chroot
  mkdir -p "$DEP/var/home"; mountpoint -q "$DEP/var/home" || domount "$ROOTPART" "$DEP/var/home" "subvol=home"
  chroot "$DEP" systemd-tmpfiles --create --prefix=/var >>"$LOG" 2>&1
  grep -q '^wheel:' "$DEP/etc/group"   || grep '^wheel:' "$DEP/usr/lib/group" >> "$DEP/etc/group"
  grep -q '^wheel:' "$DEP/etc/gshadow" || echo 'wheel:!::' >> "$DEP/etc/gshadow"
  run chroot "$DEP" useradd -m -G wheel -c "$fullname" "$user" || { msg "No se pudo crear el usuario"; return 1; }
  echo "$user:$pass" | chroot "$DEP" chpasswd
  touch "$DEP/etc/plasma-setup-done" "$DEP/etc/gnome-initial-setup-done" 2>/dev/null   # usuario ya creado: sin asistente
  install_bootloader_fresh
  repair_grub_config
  repair_uefi_entries
  label_fresh_install
  release_all
  msg "Fedora Kinoite instalado desde cero.\n\nUsuario: $user\nEquipo: $host\n\nReinicia el equipo. El primer arranque puede tardar un poco más."
}

# Etiquetas SELinux de una instalación nueva (el Rescate corre sin SELinux)
label_fresh_install() {
  log "  Aplicando etiquetas SELinux..."
  relabel /etc /var /boot
  local d
  for d in "$SYSROOT" "$SYSROOT/ostree" "$SYSROOT/ostree/deploy" "$SYSROOT/ostree/deploy/$STATEROOT" "$SYSROOT/boot"; do
    setfattr -h -n security.selinux -v "system_u:object_r:root_t:s0" "$d" 2>/dev/null
  done
  find "$SYSROOT/ostree/repo" -xdev -exec setfattr -h -n security.selinux -v "system_u:object_r:root_t:s0" {} + 2>/dev/null
  setfattr -n security.selinux -v "system_u:object_r:boot_t:s0" "$SYSROOT/boot/." 2>/dev/null
  ok "Etiquetas SELinux aplicadas"
}

install_bootloader_fresh() {
  # Primero, la forma oficial (bootupd); si falla, copia manual
  if chroot "$DEP" bootupctl backend install --write-uuid --update-firmware --with-static-configs --device "$DISK" /sysroot >>"$LOG" 2>&1; then
    ok "Cargador instalado con bootupd"
  else
    log "  bootupd falló; instalación manual del cargador"
    repair_efi_files
  fi
  [ -f "$SYSROOT/boot/efi/EFI/fedora/grub.cfg" ] || write_esp_grubcfg
}

# ================================================================ USUARIOS
reset_password() {
  prepare_chroot || return 1
  local users; users=$(awk -F: '$3>=1000 && $3<60000 {print $1" "$5}' "$DEP/etc/passwd")
  [ -n "$users" ] || { msg "No hay usuarios normales."; return; }
  local items=() u n
  while read -r u n; do items+=("$u" "${n:- }"); done <<<"$users"
  u=$(whiptail --title "Rescate" --menu "¿De qué usuario?" 15 60 6 "${items[@]}" 3>&1 1>&2 2>&3) || return
  local p1 p2
  p1=$(secret "Nueva contraseña para $u:") || return
  p2=$(secret "Repite la contraseña:") || return
  [ "$p1" = "$p2" ] || { msg "Las contraseñas no coinciden."; return; }
  echo "$u:$p1" | chroot "$DEP" chpasswd && chroot "$DEP" faillock --user "$u" --reset 2>/dev/null
  # Asegurar que siga siendo administrador
  grep -q '^wheel:' "$DEP/etc/group" || grep '^wheel:' "$DEP/usr/lib/group" >> "$DEP/etc/group"
  chroot "$DEP" usermod -aG wheel "$u"
  relabel /etc/shadow /etc/passwd /etc/group /etc/gshadow
  msg "Contraseña de $u cambiada (y desbloqueada)."
}

# ================================================================ MODO SEGURO
# Arranca Fedora UNA vez con opciones seguras; después vuelve a la normalidad.
SAFE_KARGS="nomodeset modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nouveau rd.driver.blacklist=nvidia,nouveau"
safe_mode_once() {  # $1 = grafico | texto
  mount_sysroot || return 1
  local extra="$SAFE_KARGS"; [ "$1" = texto ] && extra+=" systemd.unit=multi-user.target"
  cp "$DEPENTRY" "$DEPENTRY.rescate-normal"
  entry_del rhgb quiet; entry_add $extra
  local U="$DEP/etc/systemd/system"; mkdir -p "$U/multi-user.target.wants"
  cat > "$U/rescate-modoseguro.service" <<X
[Unit]
Description=Rescate: restaurar el arranque normal tras el modo seguro
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mount -o remount,rw /boot; for f in /boot/loader/entries/*.rescate-normal; do [ -f "\$f" ] && mv -f "\$f" "\${f%.rescate-normal}"; done'
ExecStartPost=/bin/rm -f /etc/systemd/system/rescate-modoseguro.service /etc/systemd/system/multi-user.target.wants/rescate-modoseguro.service
[Install]
WantedBy=multi-user.target
X
  ln -sf ../rescate-modoseguro.service "$U/multi-user.target.wants/rescate-modoseguro.service"
  prepare_chroot && relabel /etc/systemd/system/rescate-modoseguro.service /etc/systemd/system/multi-user.target.wants
  fixd "El próximo arranque será en MODO SEGURO ($1). El siguiente volverá a ser normal."
}

# ================================================================ PRUEBAS DE HARDWARE
REPORT=/root/informe-hardware.txt
rep()  { echo "$*" | tee -a "$REPORT"; }
pass() { rep "  [ OK ]  $*"; }
fail() { rep "  [FALLO] $*"; HWFAIL+=("$*"); }

test_ram() {  # $1 = GB a probar (por defecto: 70% de la libre)
  rep "== Memoria RAM =="
  local freemb; freemb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  local mb=${1:+$(( $1 * 1024 ))}; mb=${mb:-$(( freemb * 70 / 100 ))}
  [ "$mb" -gt $(( freemb - 512 )) ] && mb=$(( freemb - 512 ))
  rep "  Probando ${mb} MB de $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) MB (memtester, 1 pasada)..."
  if memtester "${mb}M" 1 2>&1 | tee -a "$LOG" | stdbuf -oL tr '\b' '\n' | grep --line-buffered -E 'Loop|FAILURE|ok$' | tail -n 3; [ "${PIPESTATUS[0]}" = 0 ]; then
    pass "RAM sin errores (${mb} MB probados)"
  else fail "ERRORES en la RAM: una memoria está dañada o mal colocada"; fi
  rep "  Para una prueba completa de TODA la RAM usa 'Memtest86+' en el menú de GRUB."
}

test_disk() {  # $1 = rapida | larga | superficie
  rep "== Disco =="
  local d=${DISK:-$(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1; exit}')}
  smartctl -H "$d" >>"$LOG" 2>&1 && pass "SMART: salud correcta ($d)" || fail "SMART: el disco $d reporta fallos"
  local log; log=$(smartctl -A "$d" 2>/dev/null)
  local used; used=$(echo "$log" | awk -F: '/Percentage Used/{gsub(/[ %]/,"",$2); print $2}')
  local merr; merr=$(echo "$log" | awk -F: '/Media and Data Integrity Errors/{gsub(/ /,"",$2); print $2}')
  local spare; spare=$(echo "$log" | awk -F: '/^Available Spare:/{gsub(/[ %]/,"",$2); print $2}')
  local sthr; sthr=$(echo "$log" | awk -F: '/^Available Spare Threshold:/{gsub(/[ %]/,"",$2); print $2}')
  local temp; temp=$(echo "$log" | awk -F: '/^Temperature:/{gsub(/^ +/,"",$2); print $2}')
  [ -n "$used" ]  && { [ "$used" -lt 90 ] && pass "Desgaste del SSD: ${used}%" || fail "SSD muy desgastado: ${used}%"; }
  [ -n "$merr" ]  && { [ "$merr" = 0 ] && pass "Errores de integridad de datos: 0" || fail "Errores de integridad de datos: $merr"; }
  if [ -n "$spare" ] && [ -n "$sthr" ] && [ "$sthr" -gt 0 ]; then
    [ "$spare" -gt "$sthr" ] && pass "Reserva del SSD: ${spare}% (mínimo ${sthr}%)" || fail "Reserva del SSD agotada: ${spare}% (mínimo ${sthr}%)"
  fi
  [ -n "$temp" ]  && rep "  Temperatura del disco: $temp"
  case "${1:-rapida}" in
    rapida|larga)
      local t=short; [ "$1" = larga ] && t=long
      rep "  Auto-prueba SMART ($t) en curso..."
      smartctl -t "$t" "$d" >>"$LOG" 2>&1
      while smartctl -a "$d" 2>/dev/null | grep -qiE 'Self-test (routine )?in progress|Current Self-test|% of test remaining'; do sleep 10; printf '.'; done; echo
      if smartctl -l selftest "$d" 2>/dev/null | sed -n '1,12p' | grep -qiE 'fail|error|abort'; then fail "Auto-prueba SMART con errores"; else pass "Auto-prueba SMART completada sin errores"; fi ;;
    superficie)
      rep "  Leyendo TODO el disco en busca de sectores dañados (solo lectura, tarda)..."
      if badblocks -sv -b 4096 -c 4096 "$d" 2>&1 | tee -a "$LOG" | tail -n 2 | grep -q '0 bad blocks\|(0/0/0 errors)'; then
        pass "Lectura completa sin sectores dañados"
      else fail "Se encontraron sectores ilegibles en el disco"; fi ;;
  esac
}

test_vram() {
  rep "== Memoria de video (VRAM) NVIDIA =="
  lspci -d 10de: | grep -qiE 'vga|3d' || { rep "  No hay tarjeta NVIDIA."; return; }
  rep "  Cargando controlador libre (nouveau) para la prueba..."
  modprobe nouveau 2>>"$LOG"; sleep 5
  if ! ls /dev/dri/renderD* >/dev/null 2>&1 || ! vulkaninfo --summary 2>/dev/null | grep -qi nvidia; then
    fail "La tarjeta NVIDIA no responde (ni con el controlador libre). Puede estar dañada o desactivada en la BIOS."
    return
  fi
  pass "La tarjeta NVIDIA responde ($(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/{print $2}' | grep -i nvidia | head -1 | sed 's/^ *//'))"
  rep "  Probando la VRAM durante 3 minutos (memtest_vulkan)..."
  local dev; dev=$(vulkaninfo --summary 2>/dev/null | awk '/^GPU[0-9]/{g=$1} /deviceName/ && tolower($0)~/nvidia/{sub(/GPU/,"",g); sub(/:/,"",g); print g+1; exit}')
  local out; out=$( (sleep 180; pkill -INT memtest_vulkan) & echo "${dev:-1}" | timeout 200 memtest_vulkan 2>&1 | tee -a "$LOG")
  if echo "$out" | grep -qiE 'error|mismatch'; then fail "ERRORES en la VRAM: la memoria de la tarjeta gráfica está fallando"
  elif echo "$out" | grep -qiE 'iteration|passed|written'; then pass "VRAM sin errores"
  else rep "  (No se pudo completar la prueba de VRAM; ver registro)"; fi
  rmmod nouveau 2>/dev/null
}

test_cpu() {  # $1 = segundos
  local s=${1:-120}
  rep "== Procesador y temperatura =="
  local t0; t0=$(max_temp)
  rep "  Temperatura en reposo: ${t0}°C. Estresando CPU y RAM ${s} s..."
  local maxt=0 out
  ( while sleep 5; do t=$(max_temp); [ "$t" -gt "$(cat /tmp/maxt 2>/dev/null || echo 0)" ] && echo "$t" > /tmp/maxt; done ) & local mon=$!
  out=$(stress-ng --cpu 0 --vm 2 --vm-bytes 25% --verify -t "${s}s" --metrics-brief 2>&1 | tee -a "$LOG"); local rc=${PIPESTATUS[0]}
  kill $mon 2>/dev/null; maxt=$(cat /tmp/maxt 2>/dev/null || echo 0); rm -f /tmp/maxt
  local nfail; nfail=$(echo "$out" | awk '/ failed: /{print $NF}' | tail -1)
  if [ "$rc" = 2 ] || { [ -n "$nfail" ] && [ "$nfail" != 0 ]; } || echo "$out" | grep -qiE 'verification (error|fail)'; then fail "El procesador dio errores de cálculo bajo carga"
  else pass "Procesador estable bajo carga"; fi
  if [ "$maxt" -ge 98 ]; then fail "Temperatura máxima ${maxt}°C: sobrecalentamiento (limpiar ventiladores/pasta térmica)"
  else pass "Temperatura máxima bajo carga: ${maxt}°C"; fi
  local thr; thr=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count 2>/dev/null)
  [ -n "$thr" ] && [ "$thr" -gt 0 ] && rep "  Aviso: el CPU redujo su velocidad por calor $thr veces."
}
max_temp() {
  local m=0 t; for t in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
    [ -r "$t" ] || continue; t=$(( $(cat "$t" 2>/dev/null || echo 0) / 1000 )); [ "$t" -gt "$m" ] && [ "$t" -lt 125 ] && m=$t; done; echo $m
}

test_battery() {
  rep "== Batería y cargador =="
  local b; b=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
  [ -n "$b" ] || { rep "  Sin batería."; return; }
  local full design now st cyc
  full=$(cat "$b/energy_full" 2>/dev/null || cat "$b/charge_full"); design=$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design")
  st=$(cat "$b/status"); cyc=$(cat "$b/cycle_count" 2>/dev/null)
  local h=$(( full * 100 / design ))
  [ "$h" -ge 60 ] && pass "Salud de la batería: ${h}% de su capacidad original" || fail "Batería desgastada: ${h}% de su capacidad original"
  rep "  Estado: $st | Carga: $(cat "$b/capacity")% ${cyc:+| Ciclos: $cyc}"
  local ac; ac=$(cat /sys/class/power_supply/{AC,ADP}*/online 2>/dev/null | head -1)
  [ "$ac" = 1 ] && pass "Cargador conectado y detectado" || rep "  Cargador: no conectado"
}

test_quick_all() {
  : > "$REPORT"; HWFAIL=()
  rep "INFORME DE HARDWARE — $(date)"
  rep "Equipo: $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  rep "CPU: $(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
  detect >/dev/null 2>&1
  test_disk rapida; test_ram 4; test_cpu 60; test_vram; test_battery
  rep ""
  if [ ${#HWFAIL[@]} -eq 0 ]; then rep "RESULTADO: no se encontraron fallos de hardware."
  else rep "RESULTADO: ${#HWFAIL[@]} problema(s) de hardware:"; local f; for f in "${HWFAIL[@]}"; do rep "  • $f"; done; fi
}
