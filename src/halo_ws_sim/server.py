"""WebSocket server: one connection == one simulated Halo session."""
from __future__ import annotations

import asyncio
import logging
from pathlib import Path

import websockets

from halo_ws_sim import protocol
from halo_ws_sim.bridge import HaloDeviceBridge

_log = logging.getLogger("halo_ws_sim.server")


class SimState:
    """Shared handle to the live session, read by the desktop window."""

    def __init__(self) -> None:
        self.bridge: HaloDeviceBridge | None = None
        self.device_name = protocol.DEFAULT_DEVICE_NAME
        self.device_id = protocol.DEFAULT_DEVICE_ID
        self.client_addr: str | None = None


class HaloWsServer:
    def __init__(
        self,
        state: SimState,
        *,
        host: str = "0.0.0.0",
        port: int = 8765,
        sandbox_dir: str | Path = "./halo_sandbox",
        preload_libs: list[str] | None = None,
    ) -> None:
        self.state = state
        self.host = host
        self.port = port
        self.sandbox_dir = Path(sandbox_dir)
        self.preload_libs = preload_libs or []
        self._active = None  # the live websocket connection, if any

    async def serve_forever(self) -> None:
        async with websockets.serve(
            self._handler, self.host, self.port, max_size=8 * 1024 * 1024
        ):
            _log.info("listening on ws://%s:%d", self.host, self.port)
            _log.info("  Android emulator -> ws://10.0.2.2:%d", self.port)
            await asyncio.Future()  # run until cancelled

    async def _handler(self, websocket, *_: object) -> None:
        peer = f"{websocket.remote_address[0]}:{websocket.remote_address[1]}"
        if self._active is not None:
            _log.warning("replacing existing client with %s", peer)
            await self._active.close(code=1012, reason="superseded")
        self._active = websocket
        self.state.client_addr = peer
        _log.info("client connected: %s", peer)

        loop = asyncio.get_running_loop()
        out_q: asyncio.Queue[str] = asyncio.Queue()

        def on_rx(payload: bytes) -> None:
            loop.call_soon_threadsafe(out_q.put_nowait, protocol.rx_frame(payload))

        def on_log(level: str, msg: str) -> None:
            loop.call_soon_threadsafe(out_q.put_nowait, protocol.log_frame(level, msg))

        bridge = HaloDeviceBridge(
            self.sandbox_dir,
            on_rx=on_rx,
            on_log=on_log,
            preload_libs=self.preload_libs,
        )
        self.state.bridge = bridge

        writer = asyncio.create_task(self._writer(websocket, out_q))
        try:
            async for raw in websocket:
                await self._on_message(websocket, bridge, raw)
        except websockets.ConnectionClosed:
            pass
        finally:
            writer.cancel()
            bridge.close()
            if self.state.bridge is bridge:
                self.state.bridge = None
            if self._active is websocket:
                self._active = None
                self.state.client_addr = None
            _log.info("client disconnected: %s", peer)

    async def _writer(self, websocket, out_q: asyncio.Queue[str]) -> None:
        try:
            while True:
                msg = await out_q.get()
                await websocket.send(msg)
        except (asyncio.CancelledError, websockets.ConnectionClosed):
            pass

    async def _on_message(self, websocket, bridge: HaloDeviceBridge, raw) -> None:
        try:
            msg = protocol.decode(raw)
        except Exception:  # noqa: BLE001
            _log.warning("dropping non-JSON frame")
            return

        t = msg.get("t")
        if t == "hello":
            await websocket.send(
                protocol.device_frame(
                    name=self.state.device_name, device_id=self.state.device_id
                )
            )
        elif t == "connect":
            await websocket.send(protocol.ready_frame())
        elif t == "disconnect":
            await websocket.close()
        elif t == "tx":
            data = protocol.b64d(msg.get("b64", ""))
            kind = msg.get("kind")
            if kind == "string":
                bridge.tx_string(data)
            elif kind == "data":
                bridge.tx_data(data)
            elif kind == "audio":
                bridge.tx_audio(data)
        elif t == "inject":
            arg = msg.get("arg")
            if msg.get("event") == "ble" and isinstance(arg, str):
                arg = protocol.b64d(arg)
            bridge.inject(msg.get("event", ""), arg)
        else:
            _log.warning("unknown frame type: %r", t)
