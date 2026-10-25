#!/usr/bin/env python3
"""Envía órdenes por la consola serie de la VM y espera un marcador.
uso: serial.py SOCK 'orden' [timeout_s]   -> imprime la salida hasta que termina la orden
     serial.py SOCK --wait 'texto' [timeout_s]"""
import socket, sys, time, re, uuid
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(1)
buf = b""
def read_until(pat, timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        try:
            d = s.recv(65536)
            if d:
                buf += d; sys.stdout.write(d.decode(errors="replace")); sys.stdout.flush()
        except socket.timeout:
            pass
        if re.search(pat, buf.decode(errors="replace")):
            return True
    return False
if cmd == "--wait":
    ok = read_until(sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 300)
    sys.exit(0 if ok else 1)
timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 600
m = "FIN" + uuid.uuid4().hex[:8]
s.sendall(b"\n"); time.sleep(0.5)
s.sendall((cmd + f"; echo {m}=$?\n").encode())
ok = read_until(m + r"=\d+", timeout)
sys.exit(0 if ok else 1)
