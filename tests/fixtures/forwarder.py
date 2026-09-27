#!/usr/bin/env python3
"""Tiny TCP listener / port forwarder used by the dbgrid tunnel tests.

  forwarder.py LOCAL_PORT              accept connections on 127.0.0.1:LOCAL_PORT and close them
  forwarder.py LOCAL_PORT TARGET_PORT  forward every connection to 127.0.0.1:TARGET_PORT

Runs until it is killed (SIGTERM), like a real port-forwarding session.
"""
import socket
import sys
import threading


def pump(src, dst):
    """Copy bytes from src to dst until EOF, then half-close dst."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def forward(client, target_port):
    try:
        upstream = socket.create_connection(("127.0.0.1", target_port))
    except OSError:
        client.close()
        return
    a = threading.Thread(target=pump, args=(client, upstream), daemon=True)
    b = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    a.start()
    b.start()
    a.join()
    b.join()
    client.close()
    upstream.close()


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    local_port = int(sys.argv[1])
    target_port = int(sys.argv[2]) if len(sys.argv) > 2 else None
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", local_port))
    server.listen(16)
    sys.stderr.write("forwarder: listening on 127.0.0.1:%d\n" % local_port)
    sys.stderr.flush()
    while True:
        client, _ = server.accept()
        if target_port is None:
            client.close()
            continue
        threading.Thread(target=forward, args=(client, target_port), daemon=True).start()


if __name__ == "__main__":
    main()
