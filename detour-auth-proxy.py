#!/usr/bin/env python3
"""Login helper for detour.

Chromium (and so Vesktop and Discord) can't take proxy credentials on the
command line. detour starts this helper instead: a plain HTTP proxy on
127.0.0.1 that forwards every connection to the real proxy and handles the
login there.

The upstream proxy is read from the DETOUR_UPSTREAM environment variable:
    http://user:password@host:port
    https://user:password@host:port
    socks5://user:password@host:port

The chosen local port is printed on stdout. With --parent PID the helper
exits once that process is gone and no process still runs with
--proxy-server pointing at the helper (Discord restarts itself into a newer
copy when it updates).
"""

import argparse
import asyncio
import base64
import ipaddress
import os
import ssl
import struct
import sys
from urllib.parse import unquote

BAD_GATEWAY = b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
BAD_REQUEST = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
HOP_HEADERS = ("proxy-authorization", "proxy-connection", "connection", "keep-alive")


def log(*args):
    print("detour-auth-proxy:", *args, file=sys.stderr, flush=True)


class ProxyError(Exception):
    pass


def split_hostport(text, default_port):
    """'host:port', '[v6]:port' or 'host' -> (host, port)."""
    if text.startswith("["):
        end = text.find("]")
        if end < 0:
            raise ValueError(text)
        host, rest = text[1:end], text[end + 1:]
        port = rest[1:] if rest.startswith(":") else ""
    elif text.count(":") == 1:
        host, port = text.split(":")
    else:
        host, port = text, ""
    port = int(port) if port else default_port
    if not host or not 0 < port < 65536:
        raise ValueError(text)
    return host, port


class Upstream:
    # Parsed the same way as parse_proxy in the detour script, so a password
    # with '@' or ':' in it works without percent-encoding.
    def __init__(self, url):
        scheme, sep, rest = url.partition("://")
        if not sep:
            scheme, rest = "http", url
        self.scheme = {"socks5h": "socks5", "socks": "socks5"}.get(scheme.lower(), scheme.lower())
        if self.scheme not in ("http", "https", "socks5"):
            raise ValueError(f"unsupported proxy type {scheme!r}")
        auth, _, hostport = rest.rpartition("@")
        user, _, password = auth.partition(":")
        self.user, self.password = unquote(user), unquote(password)
        self.host, self.port = split_hostport(hostport.split("/")[0], 0)
        if self.scheme == "socks5" and (len(self.user.encode()) > 255 or len(self.password.encode()) > 255):
            raise ValueError("SOCKS5 login and password must be at most 255 bytes")
        token = base64.b64encode(f"{self.user}:{self.password}".encode()).decode()
        self.auth_header = f"Proxy-Authorization: Basic {token}"

    async def open(self):
        tls = None
        if self.scheme == "https":
            tls = ssl.create_default_context()
        try:
            return await asyncio.wait_for(
                asyncio.open_connection(self.host, self.port, ssl=tls,
                                        server_hostname=self.host if tls else None),
                timeout=15)
        except (OSError, asyncio.TimeoutError) as e:
            raise ProxyError(f"can't connect to proxy {self.host}:{self.port}: {e}") from None

    async def socks5_connect(self, host, port):
        reader, writer = await self.open()
        try:
            methods = b"\x00\x02" if self.user else b"\x00"
            writer.write(b"\x05" + bytes([len(methods)]) + methods)
            _, method = await reader.readexactly(2)
            if method == 2:
                user, password = self.user.encode(), self.password.encode()
                writer.write(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
                _, status = await reader.readexactly(2)
                if status != 0:
                    raise ProxyError("SOCKS5 proxy rejected the login and password")
            elif method != 0:
                raise ProxyError("SOCKS5 proxy wants a login method that isn't supported")

            try:
                ip = ipaddress.ip_address(host)
                addr = (b"\x01" if ip.version == 4 else b"\x04") + ip.packed
            except ValueError:
                name = host.encode("idna")
                addr = b"\x03" + bytes([len(name)]) + name
            writer.write(b"\x05\x01\x00" + addr + struct.pack("!H", port))
            reply = await reader.readexactly(4)
            if reply[1] != 0:
                raise ProxyError(f"SOCKS5 proxy couldn't connect to {host}:{port} (code {reply[1]})")
            if reply[3] == 3:
                skip = (await reader.readexactly(1))[0]
            else:
                skip = 16 if reply[3] == 4 else 4
            await reader.readexactly(skip + 2)
            return reader, writer
        except (OSError, asyncio.IncompleteReadError, UnicodeError) as e:
            writer.close()
            raise ProxyError(f"SOCKS5 handshake with the proxy failed: {e}") from None
        except ProxyError:
            writer.close()
            raise


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()


class Forwarder:
    def __init__(self, upstream):
        self.up = upstream
        self.last_error = None

    def report(self, error):
        # one log line per distinct problem, not one per connection
        if str(error) != self.last_error:
            self.last_error = str(error)
            log(error)

    async def handle(self, client_reader, client_writer):
        upstream_writer = None
        try:
            try:
                head = await asyncio.wait_for(client_reader.readuntil(b"\r\n\r\n"), 60)
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError,
                    asyncio.TimeoutError, OSError):
                return
            lines = head.decode("latin-1").split("\r\n")
            try:
                method, target, version = lines[0].split(" ", 2)
            except ValueError:
                client_writer.write(BAD_REQUEST)
                return
            headers = [h for h in lines[1:] if h and h.split(":", 1)[0].strip().lower() not in HOP_HEADERS]

            try:
                if method.upper() == "CONNECT":
                    upstream_reader, upstream_writer = await self.connect_tunnel(target, version, headers, client_writer)
                else:
                    upstream_reader, upstream_writer = await self.forward_request(method, target, version, headers)
            except ValueError:
                client_writer.write(BAD_REQUEST)
                return
            except ProxyError as e:
                self.report(e)
                client_writer.write(BAD_GATEWAY)
                return

            await asyncio.gather(pipe(client_reader, upstream_writer),
                                 pipe(upstream_reader, client_writer))
        finally:
            client_writer.close()
            if upstream_writer:
                upstream_writer.close()

    async def connect_tunnel(self, target, version, headers, client_writer):
        host, port = split_hostport(target, 443)
        if self.up.scheme == "socks5":
            streams = await self.up.socks5_connect(host, port)
            client_writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            return streams

        reader, writer = await self.up.open()
        request = [f"CONNECT {target} {version}", *headers, self.up.auth_header, "", ""]
        writer.write("\r\n".join(request).encode("latin-1"))
        try:
            reply = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError,
                asyncio.TimeoutError, OSError):
            writer.close()
            raise ProxyError("proxy closed the connection without answering") from None
        status = reply.split(b" ", 2)[1:2]
        if status == [b"407"]:
            self.report("proxy rejected the login and password (HTTP 407)")
        elif status != [b"200"]:
            self.report(f"proxy refused CONNECT {target}: {reply.splitlines()[0].decode('latin-1')}")
        client_writer.write(reply)   # pass the proxy's answer on as-is
        return reader, writer

    async def forward_request(self, method, target, version, headers):
        # Plain http:// request (rare for Discord). Ask for Connection: close
        # so every request gets its own, freshly authorized connection.
        if self.up.scheme == "socks5":
            if not target.lower().startswith("http://"):
                raise ValueError(target)
            hostport, _, path = target[7:].partition("/")
            host, port = split_hostport(hostport, 80)
            reader, writer = await self.up.socks5_connect(host, port)
            request = [f"{method} /{path} {version}", *headers, "Connection: close", "", ""]
        else:
            reader, writer = await self.up.open()
            request = [f"{method} {target} {version}", *headers, self.up.auth_header,
                       "Connection: close", "", ""]
        writer.write("\r\n".join(request).encode("latin-1"))
        return reader, writer


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return True


def switch_in_use(switch):
    """Does any process have `switch` on its command line?"""
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                # Chromium may rewrite its title with spaces instead of NULs
                if switch in f.read().replace(b"\0", b" ").split():
                    return True
        except OSError:
            pass
    return False


async def main():
    parser = argparse.ArgumentParser(description="Local login helper for detour.")
    parser.add_argument("--parent", type=int, help="exit when this process is gone")
    parser.add_argument("--port", type=int, default=0, help="local port (default: any free port)")
    args = parser.parse_args()

    try:
        upstream = Upstream(os.environ.get("DETOUR_UPSTREAM", ""))
    except ValueError as e:
        log(f"bad proxy in DETOUR_UPSTREAM: {e}")
        return 2

    server = await asyncio.start_server(Forwarder(upstream).handle, "127.0.0.1", args.port)
    port = server.sockets[0].getsockname()[1]
    print(port, flush=True)
    sys.stdout.close()   # detour stops reading after the port

    switch = f"--proxy-server=http://127.0.0.1:{port}".encode()
    async with server:
        while args.parent is None or process_alive(args.parent) or switch_in_use(switch):
            await asyncio.sleep(2)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        pass
