#!/bin/bash
# shot.sh DESTINO.png — captura de pantalla de la VM
python3 "$(dirname "$0")/mon.py" ~/.cache/rescate-vm/mon.sock "screendump /work/shot.png -f png" >/dev/null; sleep 1
cp ~/.cache/rescate-vm/shot.png "$1"
