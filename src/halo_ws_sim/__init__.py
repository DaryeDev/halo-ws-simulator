"""Wireless (WebSocket) simulator of the Brilliant Labs Halo.

The upstream ``halo-emulator`` package provides the device runtime (a real
Lua 5.4 VM plus the full ``frame.*`` API and a 256x256 framebuffer). This
package wraps one emulator instance in a WebSocket server that speaks the same
byte protocol a Halo exposes over its BLE TX/RX characteristics, so a Flutter
app using the (WebSocket build of the) Halo SDK can connect to it exactly as it
would to real glasses.
"""

__version__ = "0.1.0"

from halo_ws_sim.bridge import HaloDeviceBridge

__all__ = ["HaloDeviceBridge"]
