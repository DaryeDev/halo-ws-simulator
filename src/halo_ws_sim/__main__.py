"""``halo-ws-sim`` entry point."""
from __future__ import annotations

import argparse
import asyncio
import logging
import shutil
import sys
import threading
from pathlib import Path

from halo_ws_sim.server import HaloWsServer, SimState
from halo_ws_sim.window import run_window


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="halo-ws-sim",
        description="Wireless (WebSocket) simulator of the Brilliant Labs Halo.",
    )
    p.add_argument("--host", default="0.0.0.0", help="bind address (default: 0.0.0.0)")
    p.add_argument("--port", type=int, default=8765, help="port (default: 8765)")
    p.add_argument(
        "--sandbox",
        default="./halo_sandbox",
        metavar="DIR",
        help="device 'flash' directory for uploaded Lua files (default: ./halo_sandbox)",
    )
    p.add_argument(
        "--fresh",
        action="store_true",
        help="wipe the sandbox directory on startup",
    )
    p.add_argument(
        "--libs",
        default="",
        metavar="a,b,c",
        help="brilliant_msg libs to preload as <name>.min.lua (e.g. data,plain_text)",
    )
    p.add_argument("--headless", action="store_true", help="no desktop window")
    p.add_argument(
        "--no-web",
        action="store_true",
        help="disable the HTTP observability view (default: on, port = --port + 1)",
    )
    p.add_argument(
        "--window-main-thread",
        action="store_true",
        help="run the window on the main thread and the server on a thread (macOS)",
    )
    p.add_argument("-v", "--verbose", action="count", default=0)
    return p.parse_args(argv)


def _setup_logging(verbose: int) -> None:
    level = logging.WARNING if verbose == 0 else logging.INFO if verbose == 1 else logging.DEBUG
    logging.basicConfig(
        level=level,
        format="%(asctime)s  %(levelname)-5s  %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    _setup_logging(max(args.verbose, 1))  # default to INFO so you can see clients

    sandbox = Path(args.sandbox)
    if args.fresh and sandbox.exists():
        shutil.rmtree(sandbox)
    sandbox.mkdir(parents=True, exist_ok=True)

    libs = [x.strip() for x in args.libs.split(",") if x.strip()]
    state = SimState()
    server = HaloWsServer(
        state,
        host=args.host,
        port=args.port,
        sandbox_dir=sandbox,
        preload_libs=libs,
    )

    if not args.no_web:
        from halo_ws_sim.observe import start_observe_server

        start_observe_server(state, args.port + 1)

    stop_flag = threading.Event()

    async def _run_server() -> None:
        try:
            await server.serve_forever()
        finally:
            stop_flag.set()

    if args.headless:
        try:
            asyncio.run(_run_server())
        except KeyboardInterrupt:
            pass
        return 0

    if args.window_main_thread:
        server_thread = threading.Thread(
            target=lambda: asyncio.run(_run_server()), name="halo-ws-server", daemon=True
        )
        server_thread.start()
        try:
            run_window(state, stop_flag)
        except KeyboardInterrupt:
            stop_flag.set()
        return 0

    # Default: server on main thread (clean Ctrl+C), window on a daemon thread.
    window_thread = threading.Thread(
        target=lambda: run_window(state, stop_flag), name="halo-ws-window", daemon=True
    )
    window_thread.start()
    try:
        asyncio.run(_run_server())
    except KeyboardInterrupt:
        pass
    finally:
        stop_flag.set()
    return 0


if __name__ == "__main__":
    sys.exit(main())
