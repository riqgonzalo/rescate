import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(4096)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.5); print(s.recv(65536).decode(errors="replace"))
