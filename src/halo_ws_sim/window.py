"""Desktop window: shows the 256x256 framebuffer and injects hardware events.

Runs its own loop. On Windows/Linux it is started on a daemon thread by
``__main__``; on macOS pass ``--window-main-thread`` (SDL's Cocoa backend must
init video on the main thread there).

Keys
----
  SPACE  button single click        T  IMU tap (single)
  D      button double click        2  IMU double tap
  L      button long press          3  IMU triple tap
  S      save framebuffer PNG       ESC / window close: quit
"""
from __future__ import annotations

import logging
import time

from halo_ws_sim.server import SimState

_log = logging.getLogger("halo_ws_sim.window")

SCALE = 2
SIZE = 256


def run_window(state: SimState, stop_flag) -> None:
    import pygame

    pygame.display.init()
    pygame.font.init()
    screen = pygame.display.set_mode((SIZE * SCALE, SIZE * SCALE + 28))
    pygame.display.set_caption("Halo WS Simulator")
    font = pygame.font.SysFont("consolas,menlo,monospace", 13)
    clock = pygame.time.Clock()

    # Round-lens vignette, matching the upstream emulator's look.
    win = SIZE * SCALE
    overlay = pygame.Surface((win, win), pygame.SRCALPHA)
    overlay.fill((30, 30, 30, 210))
    hole = pygame.Surface((win, win), pygame.SRCALPHA)
    hole.fill((255, 255, 255, 255))
    pygame.draw.circle(hole, (0, 0, 0, 0), (win // 2, win // 2), win // 2 - 8)
    overlay.blit(hole, (0, 0), special_flags=pygame.BLEND_RGBA_MIN)

    def bridge():
        return state.bridge

    key_actions = {
        pygame.K_SPACE: lambda b: b.inject("button_single"),
        pygame.K_d: lambda b: b.inject("button_double"),
        pygame.K_l: lambda b: b.inject("button_long"),
        pygame.K_t: lambda b: b.inject("tap", "single"),
        pygame.K_2: lambda b: b.inject("tap", "double"),
        pygame.K_3: lambda b: b.inject("tap", "triple"),
    }

    running = True
    while running and not stop_flag.is_set():
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                elif event.key == pygame.K_s and bridge() is not None:
                    name = f"halo_frame_{int(time.time())}.png"
                    bridge().emu.get_framebuffer().save(name)
                    _log.info("saved %s", name)
                elif event.key in key_actions and bridge() is not None:
                    key_actions[event.key](bridge())

        screen.fill((12, 12, 12))
        b = bridge()
        if b is not None:
            img = b.emu.get_framebuffer()
            surface = pygame.image.fromstring(img.tobytes(), (SIZE, SIZE), img.mode)
            screen.blit(pygame.transform.scale(surface, (win, win)), (0, 0))
            screen.blit(overlay, (0, 0))
            status = f"connected: {state.client_addr}"
            color = (120, 230, 140)
        else:
            status = "waiting for a client..."
            color = (210, 180, 90)
        screen.blit(font.render(status, True, color), (8, win + 7))
        pygame.display.flip()
        clock.tick(30)

    stop_flag.set()
    pygame.display.quit()
