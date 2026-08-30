"""JSON envelope protocol spoken over the WebSocket.

The link stands in for the Halo BLE GATT service
``7a230001-5475-a6a4-654c-8431f6ad49c4`` with its TX (host->device) and
RX (device->host) characteristics. Every frame is a JSON object with a ``t``
(type) field. Binary payloads are base64 in ``b64``.

Host (Flutter) -> Simulator
---------------------------
{"t": "hello"}
    Discovery. Simulator replies with a ``device`` frame.
{"t": "connect"}
    Open a session (equivalent to GATT connect + enable notifications).
    Simulator replies with a ``ready`` frame.
{"t": "tx", "kind": "string", "b64": "..."}
    A write to the TX characteristic carrying a UTF-8 Lua REPL string, or a
    single control byte: 0x03 break, 0x04 reset, 0x05 remove.
{"t": "tx", "kind": "data", "b64": "..."}
    A write to the TX characteristic carrying a framed data packet
    ``[0x01, msg_code, (len_hi, len_lo on first chunk), payload...]``.
{"t": "tx", "kind": "audio", "b64": "..."}
    A write to the audio TX characteristic. Accepted and ignored.
{"t": "inject", "event": "...", "arg": ...}
    Simulator-only: inject a hardware event (see EVENTS below).
{"t": "disconnect"}
    Close the session.

Simulator -> Host (Flutter)
---------------------------
{"t": "device", "name": "...", "id": "...", "deviceType": "halo",
 "maxStringLength": N, "maxDataLength": N, "firmware": "..."}
{"t": "ready"}
{"t": "rx", "b64": "..."}
    An RX characteristic notification. First byte 0x01 => data response
    (``[0x01, payload...]``); anything else => a stdout/string response
    (typically Lua ``print()`` output or an error message).
{"t": "log", "level": "info|warn|error", "msg": "..."}
"""
from __future__ import annotations

import base64
import json
from typing import Any

# BLE-ish identity the simulator advertises.
DEFAULT_DEVICE_NAME = "Halo Sim 01"
DEFAULT_DEVICE_ID = "halo-sim-00000001"
DEVICE_TYPE = "halo"

# Matches a real Halo's usable characteristic sizes closely enough:
# a 512-byte MTU minus the ATT + brilliant_ble framing overhead.
MAX_STRING_LENGTH = 507
MAX_DATA_LENGTH = 506

# Control bytes carried in a "string" TX write (see brilliant_device.dart).
CTRL_BREAK = 0x03
CTRL_RESET = 0x04
CTRL_REMOVE = 0x05

# Injectable hardware events: event -> allowed args
EVENTS = {
    "button_single": (None,),
    "button_double": (None,),
    "button_long": (None,),
    "tap": ("single", "double", "triple"),
    "ble": None,  # arg = base64 bytes delivered straight to receive_callback
}


def encode(obj: dict[str, Any]) -> str:
    return json.dumps(obj, separators=(",", ":"))


def decode(raw: str | bytes) -> dict[str, Any]:
    return json.loads(raw)


def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(text: str) -> bytes:
    return base64.b64decode(text)


def device_frame(
    *,
    name: str = DEFAULT_DEVICE_NAME,
    device_id: str = DEFAULT_DEVICE_ID,
    firmware: str = "0.8.8-emulator",
) -> str:
    return encode(
        {
            "t": "device",
            "name": name,
            "id": device_id,
            "deviceType": DEVICE_TYPE,
            "maxStringLength": MAX_STRING_LENGTH,
            "maxDataLength": MAX_DATA_LENGTH,
            "firmware": firmware,
        }
    )


def ready_frame() -> str:
    return encode({"t": "ready"})


def rx_frame(payload: bytes) -> str:
    return encode({"t": "rx", "b64": b64e(payload)})


def log_frame(level: str, msg: str) -> str:
    return encode({"t": "log", "level": level, "msg": msg})
