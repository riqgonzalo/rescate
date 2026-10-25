# Rescate

Herramienta de emergencia para **Fedora Kinoite** (y otros Fedora Atómicos) que se
instala en el propio disco y se arranca desde **GRUB**. Se carga entera en la memoria
RAM, así que puede reparar el disco con total libertad, y abre un menú sencillo en
español.

```
┌──────────────────────── Rescate ────────────────────────┐
│ Internet: CONECTADO                                      │
│                                                          │
│  1 Reparación automática (recomendado)                   │
│  2 Conectar a internet (Wi-Fi, cable, teléfono)          │
│  3 Bluetooth                                             │
│  4 Reparar el arranque                                   │
│  5 Entrar en modo seguro                                 │
│  6 NVIDIA / pantalla negra                               │
│  7 Volver a una versión anterior de Fedora               │
│  8 Pruebas de hardware (RAM, disco, VRAM, CPU)           │
│  9 Discos y espacio                                      │
│  0 Contraseñas, SELinux, copia de archivos, terminal     │
│  I Actualizar o reinstalar Fedora Kinoite                │
│  R Reiniciar   B Reiniciar en la BIOS   A Apagar         │
└──────────────────────────────────────────────────────────┘
```

## Entradas que añade a GRUB

| Entrada | Para qué |
|---|---|
| **Rescate - reparar Fedora** | Abre el menú de Rescate (desde `/boot/rescate`). |
| **Rescate - copia de emergencia** | La misma herramienta guardada en la partición btrfs, por si `/boot` se daña. |
| **Fedora - modo seguro** | Arranca tu Fedora sin NVIDIA y con gráficos básicos (`nomodeset`). |
| **Fedora - modo seguro (solo texto)** | Igual, sin escritorio. |
| **Memtest86+** | Prueba completa de la RAM (requiere Secure Boot desactivado). |
| **Reiniciar / Apagar** | - |

Las entradas se regeneran solas al arrancar y después de cada actualización de
Fedora (servicio `rescate-grub`), así que el modo seguro siempre usa la versión
actual. El menú de GRUB queda visible 5 segundos.

## Qué repara

**Reparación automática** (una sola opción, sin preguntas):

- Revisa y repara los sistemas de archivos (EFI, `/boot`, btrfs).
- Libera espacio si `/boot` o el disco están llenos (versiones viejas de ostree).
- Comprueba las entradas de arranque de Fedora (kernel, initramfs, `root=UUID`) y
  las regenera con `ostree admin deploy` si están rotas.
- Restaura `shimx64.efi`, `grubx64.efi` y `BOOTX64.EFI` desde la copia que trae el
  propio sistema y reescribe los `grub.cfg`.
- Repara el menú UEFI del equipo: borra entradas que apuntan a discos que ya no
  existen, recrea la de Fedora y la pone primero.
- Corrige `/etc/fstab` (UUID equivocados; discos externos ausentes pasan a `nofail`
  para que no manden a modo de emergencia).
- NVIDIA: si el módulo no se compiló para el kernel nuevo, arranca con la versión
  anterior que sí lo tiene y programa la reconstrucción del controlador en el
  siguiente arranque con internet. Si ninguna versión lo tiene, arranca con la
  gráfica Intel.
- Revisa la salud del disco (SMART).

**Menús manuales**: cada reparación por separado, volver a cualquier versión
instalada, modo seguro de un solo uso, cambiar o desbloquear contraseñas, reparar
etiquetas SELinux, restablecer `/etc` de fábrica conservando usuarios y Wi‑Fi, ver
los errores del último arranque, copiar `/home` a un USB, terminal dentro del
sistema instalado.

**Actualizar / reinstalar** (necesita internet; descarga con firma GPG de Fedora):

- *Actualizar* o *Reinstalar conservando archivos*: despliega un Fedora Kinoite
  limpio sin tocar `/home` ni `/var`. Los paquetes añadidos con `rpm-ostree install`
  (incluido NVIDIA y RPM Fusion) se reinstalan solos en el primer arranque. La
  versión anterior queda en GRUB por si acaso.
- *Reinstalar desde cero*: borra el disco, crea particiones (EFI, `/boot`, btrfs con
  `root`/`home`/`var`), instala Kinoite, crea tu usuario y vuelve a instalar Rescate.

**Internet y Bluetooth**: Wi‑Fi (`nmtui`), cable, internet del teléfono por USB o
por Bluetooth, y emparejar teclados/ratones Bluetooth.

**Pruebas de hardware**: RAM (memtester y Memtest86+), disco (SMART corta/larga,
lectura de toda la superficie), VRAM de NVIDIA (memtest_vulkan con el controlador
libre), CPU bajo estrés con temperaturas, batería y cargador. Genera un informe
con OK / FALLO.

## Instalar

En el Fedora Kinoite que quieres proteger:

```bash
git clone https://github.com/riqgonzalo/rescate.git
cd rescate
sudo ./instalar.sh
```

El instalador descarga la imagen ya construida desde *Releases* (≈700 MB, verificada
con SHA-256). Necesita ~1,1 GB libres en `/boot`.

Opcional: `sudo ./instalar.sh --limpiar-uefi` borra del menú UEFI las entradas de
otros sistemas (Ubuntu, Windows, Fedoras viejos) y deja solo el Fedora actual.
Desinstalar: `sudo ./instalar.sh --desinstalar`.

## Construir la imagen uno mismo

Solo necesita `podman` (sin root):

```bash
./build.sh        # deja vmlinuz, initramfs.img, rootfs.img y memtest.efi en out/
```

Es un Fedora 44 mínimo en modo texto (kernel firmado de Fedora, NetworkManager,
BlueZ, firmware de Wi‑Fi/Bluetooth Intel, Realtek, MediaTek, Atheros y Broadcom,
ostree/rpm-ostree, herramientas de disco y de pruebas) comprimido en squashfs y
arrancado con `dmsquash-live` en RAM.

## Pruebas

`test/` tiene una máquina virtual UEFI con disco NVMe (QEMU dentro de podman) con la
que se probó: arrancar Rescate, instalar Kinoite desde cero, romper el arranque
(cargadores EFI, `grub.cfg`, entradas UEFI, `fstab`) y repararlo con la reparación
automática.

```bash
test/vm.sh init && test/vm.sh rescate     # arranca Rescate en la VM
test/serial.py ~/.cache/rescate-vm/serial.sock 'rescate auto'
```

## Uso desde la terminal de Rescate

```
rescate                     # menú
rescate auto                # reparación automática sin preguntas
rescate reinstalar          # reinstalar conservando archivos
```

## Licencia

MIT.
