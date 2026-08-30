"""Glue between the WebSocket protocol and one ``halo_emulator.HaloEmulator``.

Responsibilities
----------------
* Own the single Lua-worker thread (the only thread allowed to call into lupa).
* Translate TX writes:
    - "string" writes -> Lua REPL execution, or a break/reset/remove control.
    - "data" writes   -> ``inject_bluetooth_data`` (the device-side ``data.lua``
      re-assembles chunks and ACKs).
* Translate device output back to RX notifications:
    - Lua ``print(...)``            -> string notification (no 0x01 prefix).
    - ``frame.bluetooth.send(x)``   -> data notification (``b"\\x01" + x``).

REPL vs. running app
--------------------
A Halo has a REPL: strings written before an app starts (``sendBreakSignal``,
``uploadScript``'s ``f:write(...)``, palette setup, ...) execute immediately.
When the host writes something that starts a main loop
(e.g. ``require('frame_app')``), that call blocks inside the worker thread and
its ``frame.sleep()`` loop services injected events - exactly like hardware.
A subsequent break byte unwinds it cleanly; further strings then run again.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from pathlib import Path
from typing import Callable

from halo_emulator import HaloEmulator
from halo_emulator.event_queue import Event
from halo_emulator.stubs.system import (
    EmulatorRestartException,
    EmulatorStopException,
)

from halo_ws_sim import protocol

_log = logging.getLogger("halo_ws_sim.bridge")

# Sentinels pushed onto the worker's exec queue.
_SHUTDOWN = object()
_REBUILD = object()

# A break byte only interrupts execution that has been running for at least
# this long; anything faster is treated as an already-finished REPL command.
_BREAK_MIN_RUNTIME_S = 0.08


class HaloDeviceBridge:
    def __init__(
        self,
        sandbox_dir: str | Path,
        *,
        on_rx: Callable[[bytes], None],
        on_log: Callable[[str, str], None] | None = None,
        preload_libs: list[str] | None = None,
    ) -> None:
        """
        Parameters
        ----------
        sandbox_dir:
            Directory used as the device "flash" - uploaded Lua files land here
            and survive across sessions (like a real Halo).
        on_rx:
            Called (from the worker thread) with the raw bytes of every RX
            notification. Must be cheap and thread-safe - typically it hands the
            bytes to the asyncio loop via ``call_soon_threadsafe``.
        on_log:
            Optional ``(level, message)`` sink for human-readable diagnostics.
        preload_libs:
            brilliant_msg lib names (e.g. ``["data", "plain_text"]``) to copy
            into the sandbox as ``<name>.min.lua`` before any app runs.
        """
        self._sandbox = Path(sandbox_dir)
        self._sandbox.mkdir(parents=True, exist_ok=True)
        self._on_rx = on_rx
        self._on_log = on_log or (lambda level, msg: None)

        self.emu = HaloEmulator(sandbox_dir=self._sandbox, print_handler=self._on_print)
        # Persists across connect()/rebuild - same stub instance is reused.
        self.emu._bluetooth.add_send_listener(self._on_lua_send)

        if preload_libs:
            self._preload_libs(preload_libs)

        self._exec_q: "queue.Queue[object]" = queue.Queue()
        self._exec_start: float | None = None
        self._alive = True

        self.emu.connect()  # build the initial Lua runtime
        self._worker = threading.Thread(
            target=self._run, name="halo-lua-worker", daemon=True
        )
        self._worker.start()
        self._log("info", f"device ready (sandbox: {self._sandbox})")

    # ------------------------------------------------------------------ TX (host -> device)

    def tx_string(self, data: bytes) -> None:
        """A write to the TX characteristic that carries a string / control byte."""
        if len(data) == 1 and data[0] in (
            protocol.CTRL_BREAK,
            protocol.CTRL_RESET,
            protocol.CTRL_REMOVE,
        ):
            if data[0] == protocol.CTRL_BREAK:
                self._log("info", "break")
                self._interrupt()
            elif data[0] == protocol.CTRL_RESET:
                self._log("info", "reset")
                self._interrupt()
                self._exec_q.put(_REBUILD)
            else:  # CTRL_REMOVE
                self._log("info", "remove")
                self._interrupt()
                self._exec_q.put(_REBUILD)
            return

        # latin-1 is the only 1:1 byte<->str mapping; lupa's runtime is
        # configured the same way, so a UTF-8 payload from the host reaches the
        # Lua VM byte-identical to what a real Halo REPL would receive.
        code = data.decode("latin-1")
        self._log("debug", f"repl <- {code!r}")
        self._exec_q.put(code)

    def tx_data(self, data: bytes) -> None:
        """A write to the TX characteristic that carries a framed data packet.

        brilliant_ble prepends a 0x01 "raw data" marker to every packet; the
        firmware strips it before calling ``frame.bluetooth.receive_callback``.
        Multi-chunk messages are re-assembled device-side by ``data.lua``.
        """
        if data and data[0] == 0x01:
            data = data[1:]
        if not data:
            return
        self.emu.inject_bluetooth_data(data)

    def tx_audio(self, data: bytes) -> None:  # noqa: ARG002 - accepted, ignored
        pass

    # ------------------------------------------------------------------ event injection

    def inject(self, event: str, arg: object = None) -> None:
        if event == "button_single":
            self.emu.inject_button_single()
        elif event == "button_double":
            self.emu.inject_button_double()
        elif event == "button_long":
            self.emu.inject_button_long()
        elif event == "tap":
            self.emu.inject_imu_tap(str(arg or "single"))
        elif event == "ble":
            if isinstance(arg, (bytes, bytearray)):
                self.emu.inject_bluetooth_data(bytes(arg))
        else:
            self._log("warn", f"unknown inject event: {event}")

    # ------------------------------------------------------------------ lifecycle

    def close(self) -> None:
        self._alive = False
        self._interrupt()
        self._exec_q.put(_SHUTDOWN)
        try:
            self.emu.stop()
        except Exception:  # noqa: BLE001
            pass
        self._worker.join(timeout=2.0)

    # ------------------------------------------------------------------ worker thread

    def _run(self) -> None:
        while self._alive:
            item = self._exec_q.get()
            if item is _SHUTDOWN:
                break
            if item is _REBUILD:
                self._rebuild()
                continue

            assert isinstance(item, str)
            self._exec_start = time.monotonic()
            try:
                self.emu._lua.execute(item)
            except EmulatorRestartException:
                self._rebuild()
            except EmulatorStopException:
                pass  # clean break / reboot
            except BaseException as exc:  # noqa: BLE001 - Lua errors reach stdout
                text = self._lua_error_text(exc)
                self._log("warn", f"lua error: {text}")
                self._safe_rx(text.encode("latin-1", "replace"))
            finally:
                self._exec_start = None
                self.emu._stop_event.clear()

    def _rebuild(self) -> None:
        """Fresh Lua VM (like a reboot). Sandbox / uploaded files are kept."""
        self.emu._stop_event.clear()
        self.emu.connect()
        self._log("info", "lua runtime rebuilt")

    def _interrupt(self) -> None:
        """Stop a running main loop, if one has been executing long enough."""
        started = self._exec_start
        if started is not None and (time.monotonic() - started) > _BREAK_MIN_RUNTIME_S:
            self.emu._stop_event.set()
            self.emu._event_queue.put(Event(type="stop"))

    # ------------------------------------------------------------------ device -> host

    def _on_print(self, line: str) -> None:
        # Lua print() -> stdout stream. brilliant_ble treats any notification
        # whose first byte != 0x01 as a string response. Encode latin-1 to keep
        # the device's raw byte stream intact (print output is normally ASCII).
        self._safe_rx(line.encode("latin-1", "replace"))

    def _on_lua_send(self, raw: bytes) -> None:
        # frame.bluetooth.send(x) -> data stream. The firmware marks it with a
        # leading 0x01 so the host routes it to dataResponse.
        self._safe_rx(b"\x01" + raw)

    def _safe_rx(self, payload: bytes) -> None:
        try:
            self._on_rx(payload)
        except Exception:  # noqa: BLE001
            _log.exception("on_rx handler failed")

    # ------------------------------------------------------------------ helpers

    def _preload_libs(self, names: list[str]) -> None:
        try:
            from importlib.resources import files

            pkg = files("brilliant_msg")
        except Exception:  # noqa: BLE001
            self._log(
                "warn",
                "preload_libs requested but brilliant-msg is not installed "
                "(pip install 'halo-ws-simulator[msg]')",
            )
            return
        for name in names:
            try:
                content = pkg.joinpath(f"lua/{name}.min.lua").read_text(encoding="utf-8")
            except Exception:  # noqa: BLE001
                self._log("warn", f"no such brilliant_msg lib: {name}")
                continue
            (self._sandbox / f"{name}.min.lua").write_text(content, encoding="utf-8")
            self._log("info", f"preloaded {name}.min.lua")

    @staticmethod
    def _lua_error_text(exc: BaseException) -> str:
        # lupa surfaces Lua errors as LuaError with the message as str(exc).
        text = str(exc).strip()
        return text or exc.__class__.__name__

    def _log(self, level: str, msg: str) -> None:
        _log.log(getattr(logging, level.upper(), logging.INFO), msg)
        try:
            self._on_log(level, msg)
        except Exception:  # noqa: BLE001
            pass
