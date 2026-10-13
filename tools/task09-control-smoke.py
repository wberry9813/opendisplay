#!/usr/bin/env python3
"""Unsigned --engine control-only smoke. Never requests a display session or TCC grant.

Run with the built sender executable as argv[1]. Default Bonjour/usbmux discovery
remains enabled; this script does not interact with any macOS permission UI.
Refuses to run if the default control socket is already present.
"""
import json
import os
import socket
import stat
import struct
import subprocess
import sys
import time
from pathlib import Path

PATH = Path.home() / "Library/Application Support/SideLinker/Direct/engine.sock"
EVENTS = set()


def receive(client):
    def exact(count):
        data = b""
        while len(data) < count:
            chunk = client.recv(count - len(data))
            if not chunk:
                raise RuntimeError("unexpected EOF")
            data += chunk
        return data
    length = struct.unpack(">I", exact(4))[0]
    assert 0 < length <= 262144
    message = json.loads(exact(length))
    if message.get("kind") == "event":
        EVENTS.add(message["event"])
        if message["event"] == "sessionState":
            assert message["payload"]["state"] == "idle" and "sessionID" not in message["payload"], "discovery created a session without startSession"
    return message


def request(client, method, params=None, identifier="smoke"):
    body = json.dumps(dict(v=1, kind="request", id=identifier,
                           method=method, params=params or {})).encode()
    packet = struct.pack(">I", len(body)) + body
    # Actual fragmented header/body delivery, unlike a single sendall fixture.
    client.sendall(packet[:2])
    client.sendall(packet[2:7])
    client.sendall(packet[7:])
    while True:
        message = receive(client)
        if message["kind"] == "response" and message["id"] == identifier:
            return message


def launch(executable):
    process = subprocess.Popen([executable, "--engine"])
    try:
        end = time.monotonic() + 30
        while not PATH.exists():
            assert process.poll() is None, "engine exited before socket startup"
            assert time.monotonic() < end, "socket startup deadline"
            time.sleep(0.05)
        assert stat.S_IMODE(PATH.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE(PATH.stat().st_mode) == 0o600
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(str(PATH))
        return process, client
    except BaseException:
        process.terminate()
        process.wait(timeout=5)
        raise


def main():
    assert not os.path.lexists(PATH), "existing engine/socket; smoke must not disturb it"
    executable = sys.argv[1]
    process, client = launch(executable)
    try:
        assert not request(client, "listReceivers")["ok"]
        hello = request(client, "hello")
        assert hello["ok"] and hello["result"]["protocolVersion"] == 1
        assert request(client, "subscribe")["ok"]
        assert isinstance(request(client, "listReceivers")["result"]["receivers"], list)
        assert {"engineState", "receiverSnapshot", "sessionState", "permissionState"} <= EVENTS
        assert request(client, "unknownFixtureMethod")["error"]["code"] == "protocol.unknownMethod"
        assert request(client, "stopSession")["ok"]
        assert "diagnostic" in EVENTS
        second = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        second.settimeout(5)
        second.connect(str(PATH))
        assert receive(second)["error"]["code"] == "control.ownerExists"
        second.close()
        assert request(client, "shutdown")["ok"]
        process.wait(timeout=5)
        assert not PATH.exists(), "shutdown socket cleanup"
        print("PASS: unsigned headless hello/subscribe/list/error/second-owner/stop/shutdown; 0700/0600")
    finally:
        client.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    process, client = launch(executable)
    try:
        assert request(client, "hello")["ok"]
        start = time.monotonic()
        client.close()
        process.wait(timeout=5)
        assert not PATH.exists()
        print(f"PASS: owner EOF exits and cleans socket in {time.monotonic() - start:.3f}s (no display session)")
    finally:
        client.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
    print("LIMIT: no signed launch, capture, virtual display, receiver media, TCC grant, hardware or GUI acceptance")


if __name__ == "__main__":
    main()
