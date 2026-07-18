#!/usr/bin/env python3
"""Upload a built artifact (the APK by default) to the project's SFTP host.

Credentials come from the environment so nothing sensitive lives in the repo:

    SFTP_HOST   sftp server hostname          (required)
    SFTP_USER   username                       (required)
    SFTP_PW     password                       (required)
    SFTP_DIR    remote directory               (optional; default = login home)
    SFTP_PORT   port                           (optional; default 22)

Usage:
    SFTP_HOST=... SFTP_USER=... SFTP_PW=... python3 tools/sftp_deploy.py build/slopfarm.apk

The concrete values for this project live in .deploy/sftp.md (gitignored). Run this
from a machine with normal outbound network: a sandbox whose egress proxy only
passes HTTPS will block SSH/SFTP (this script tries an HTTP CONNECT tunnel as a
fallback, but a TLS-intercepting proxy still resets the SSH stream).
"""
import os
import posixpath
import socket
import sys

try:
    import paramiko
except ImportError:
    sys.exit("paramiko is required:  python3 -m pip install paramiko")


def _direct(host, port):
    return socket.create_connection((host, port), timeout=30)


def _via_proxy(host, port, proxy_url):
    # Parse http://h:p
    hp = proxy_url.split("://", 1)[-1].rstrip("/")
    ph, pp = hp.split(":")
    s = socket.create_connection((ph, int(pp)), timeout=30)
    s.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n" % (host, port, host, port)).encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        b = s.recv(1)
        if not b:
            raise OSError("proxy closed during CONNECT")
        resp += b
    if b"200" not in resp.split(b"\r\n", 1)[0]:
        raise OSError("proxy CONNECT refused: %r" % resp.split(b"\r\n", 1)[0])
    return s


def main():
    local = sys.argv[1] if len(sys.argv) > 1 else "build/slopfarm.apk"
    if not os.path.isfile(local):
        sys.exit("no such file: %s" % local)
    host = os.environ.get("SFTP_HOST")
    user = os.environ.get("SFTP_USER")
    pw = os.environ.get("SFTP_PW")
    if not (host and user and pw):
        sys.exit("set SFTP_HOST, SFTP_USER and SFTP_PW in the environment")
    port = int(os.environ.get("SFTP_PORT", "22"))
    remote_dir = os.environ.get("SFTP_DIR", "")

    try:
        sock = _direct(host, port)
    except OSError as e:
        proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
        if not proxy:
            sys.exit("cannot reach %s:%d (%s) and no HTTPS_PROXY to tunnel through" % (host, port, e))
        print("direct connect failed (%s); trying HTTP CONNECT tunnel via %s" % (e, proxy))
        sock = _via_proxy(host, port, proxy)

    t = paramiko.Transport(sock)
    t.start_client(timeout=30)
    t.auth_password(user, pw)
    sftp = paramiko.SFTPClient.from_transport(t)
    remote = posixpath.join(remote_dir, os.path.basename(local)) if remote_dir else os.path.basename(local)
    sftp.put(local, remote)
    size = sftp.stat(remote).st_size
    where = sftp.normalize(remote)
    print("uploaded %s -> %s (%d bytes)" % (local, where, size))
    sftp.close()
    t.close()


if __name__ == "__main__":
    main()
