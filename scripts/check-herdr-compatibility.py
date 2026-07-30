#!/usr/bin/python3
"""Read-only production compatibility check for running Herdr sessions."""

from __future__ import annotations

import json
import re
import socket
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

SUPPORTED_PROTOCOLS = {17, 18}
SOCKET_TIMEOUT_SECONDS = 1.0


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 2:
    fail("usage: check-herdr-compatibility.py /absolute/path/to/herdr")

herdr = Path(sys.argv[1])
if not herdr.is_absolute() or not herdr.is_file():
    fail("Herdr executable path must be an absolute regular file")

version = subprocess.run(
    [str(herdr), "--version"],
    check=False,
    capture_output=True,
    text=True,
    timeout=5,
)
if version.returncode != 0 or not re.fullmatch(
    r"herdr [0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9_.-]+)?\n?",
    version.stdout,
):
    fail("Herdr --version did not return a recognized version")

listing = subprocess.run(
    [str(herdr), "session", "list", "--json"],
    check=False,
    capture_output=True,
    text=True,
    timeout=5,
)
if listing.returncode != 0:
    fail(f"Herdr session discovery failed: {listing.stderr.strip()}")
try:
    sessions = json.loads(listing.stdout)["sessions"]
except (json.JSONDecodeError, KeyError, TypeError):
    fail("Herdr session discovery returned incompatible JSON")

running = [session for session in sessions if session.get("running") is True]
if not running:
    fail("production activation requires at least one running Herdr session")

observed: list[str] = []
for session in running:
    name = session.get("name")
    socket_path = session.get("socket_path")
    if not isinstance(name, str) or not name or not isinstance(socket_path, str):
        fail("running Herdr session metadata is incomplete")
    path = Path(socket_path)
    if not path.is_absolute():
        fail(f"Herdr session {name!r} returned a non-absolute socket path")

    request = {
        "id": "xeneon-edge-compatibility",
        "method": "ping",
        "params": {},
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(SOCKET_TIMEOUT_SECONDS)
            client.connect(str(path))
            client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
            response_bytes = b""
            while b"\n" not in response_bytes:
                chunk = client.recv(65536)
                if not chunk:
                    fail(f"Herdr session {name!r} closed during compatibility ping")
                response_bytes += chunk
                if len(response_bytes) > 1_048_576:
                    fail(f"Herdr session {name!r} returned an oversized ping response")
    except (OSError, TimeoutError) as error:
        fail(f"Herdr session {name!r} compatibility ping failed: {error}")

    try:
        response = json.loads(response_bytes.split(b"\n", 1)[0])
        result = response["result"]
        protocol = result["protocol"]
        server_version = result["version"]
    except (json.JSONDecodeError, KeyError, TypeError):
        fail(f"Herdr session {name!r} returned an incompatible ping response")
    if response.get("id") != request["id"]:
        fail(f"Herdr session {name!r} returned a mismatched ping response")
    if protocol not in SUPPORTED_PROTOCOLS or not isinstance(server_version, str):
        fail(
            f"Herdr session {name!r} uses unsupported protocol {protocol!r}; "
            f"supported protocols are {sorted(SUPPORTED_PROTOCOLS)}"
        )
    observed.append(f"{name}=protocol-{protocol}")

print(f"ok: compatible Herdr runtime: {', '.join(observed)}")
