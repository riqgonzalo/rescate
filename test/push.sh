#!/bin/bash
# Copia los scripts actuales de src/ dentro de la VM (por la consola serie, en base64)
cd "$(dirname "$0")/../src"
for f in rescate rescate-lib.sh rescate-grub; do
  b=$(base64 -w0 "$f")
  python3 ../test/serial.py ~/.cache/rescate-vm/serial.sock "echo $b | base64 -d > /usr/local/sbin/$f && chmod +x /usr/local/sbin/$f" 60 >/dev/null || echo "fallo $f"
done
echo copiado
