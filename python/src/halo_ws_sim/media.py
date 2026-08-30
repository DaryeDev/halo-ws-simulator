"""Bridge the host PC's real microphone / speakers / webcam into the simulated
Halo's ``frame.microphone`` / ``frame.speaker`` / ``frame.camera``.

All three are **opt-in** (``--mic`` / ``--speaker`` / ``--camera``) and need the
media extra::

    pip install "halo-ws-simulator[media]"

Formats are converted to what the real firmware produces / consumes:

* microphone -> mono 16-bit PCM at the rate the Lua app asked for (8000/16000)
* speaker    -> whatever ``frame.speaker.start{}`` configured, played on the PC
* camera     -> square JPEG at the requested resolution/quality, rotated so that
               the SDK's ``RxPhoto`` (which rotates -90 deg) yields an upright image
"""
from __future__ import annotations

import logging
import threading
from typing import Callable

_log = logging.getLogger("halo_ws_sim.media")

# quality enum (camera.lua) -> JPEG quality
_JPEG_QUALITY = {
    "VERY_LOW": 10,
    "LOW": 25,
    "MEDIUM": 50,
    "HIGH": 75,
    "VERY_HIGH": 92,
}


def _opt(cfg: object, name: str, default):
    if cfg is None:
        return default
    try:
        val = getattr(cfg, name)
    except AttributeError:
        return default
    return default if val is None else val


def _to_bytes(data: object) -> bytes:
    if isinstance(data, (bytes, bytearray)):
        return bytes(data)
    return str(data).encode("latin-1")


# ----------------------------------------------------------------------- mic


class MicBridge:
    def __init__(self, device: str | int | None) -> None:
        self._device = device
        self._stream = None
        self._on_pcm: Callable[[bytes], None] | None = None
        self._target_rate = 8000
        self._capture_rate = 48000

    def start(self, target_rate: int, on_pcm: Callable[[bytes], None]) -> None:
        self.stop()
        import numpy as np
        import sounddevice as sd

        self._on_pcm = on_pcm
        self._target_rate = int(target_rate)
        info = sd.query_devices(self._device, "input")
        self._capture_rate = int(info["default_samplerate"] or 48000)
        ratio = self._target_rate / self._capture_rate
        carry = np.zeros(0, dtype=np.float32)

        def cb(indata, _frames, _time, status):  # noqa: ANN001
            nonlocal carry
            if status:
                _log.debug("mic status: %s", status)
            mono = indata.mean(axis=1).astype(np.float32)
            mono = np.concatenate([carry, mono])
            n_out = int(len(mono) * ratio)
            if n_out < 1:
                carry = mono
                return
            xp = np.arange(len(mono))
            x = np.linspace(0, len(mono) - 1, n_out)
            out = np.interp(x, xp, mono)
            consumed = int(n_out / ratio)
            carry = mono[consumed:]
            pcm = np.clip(out * 32767, -32768, 32767).astype("<i2").tobytes()
            if self._on_pcm is not None:
                self._on_pcm(pcm)

        self._stream = sd.InputStream(
            samplerate=self._capture_rate,
            channels=max(1, min(2, int(info["max_input_channels"]) or 1)),
            dtype="float32",
            device=self._device,
            callback=cb,
            blocksize=0,
        )
        self._stream.start()
        _log.info(
            "mic: %s @ %d Hz -> %d Hz mono PCM",
            info["name"], self._capture_rate, self._target_rate,
        )

    def stop(self) -> None:
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:  # noqa: BLE001
                pass
            self._stream = None


# --------------------------------------------------------------------- speaker


class SpeakerBridge:
    def __init__(self, device: str | int | None) -> None:
        self._device = device
        self._stream = None
        self._lock = threading.Lock()

    def start(self, rate: int, channels: int, bit_depth: int) -> None:
        self.stop()
        import sounddevice as sd

        self._depth = int(bit_depth)
        self._stream = sd.RawOutputStream(
            samplerate=int(rate),
            channels=max(1, int(channels)),
            dtype="int16" if self._depth == 16 else "int8",
            device=self._device,
        )
        self._stream.start()
        _log.info("speaker: %d Hz, %d ch, %d-bit", rate, channels, bit_depth)

    def write(self, pcm: bytes) -> None:
        with self._lock:
            if self._stream is not None and pcm:
                try:
                    self._stream.write(pcm)
                except Exception as e:  # noqa: BLE001
                    _log.debug("speaker write: %s", e)

    def stop(self) -> None:
        with self._lock:
            if self._stream is not None:
                try:
                    self._stream.stop()
                    self._stream.close()
                except Exception:  # noqa: BLE001
                    pass
                self._stream = None


# ---------------------------------------------------------------------- camera


class CameraBridge:
    """Implements the ``frame.camera.*`` surface `camera.lua` needs, backed by a
    webcam. Faithful for the standard capture -> read/read_raw photo flow."""

    def __init__(self, index: int) -> None:
        self._index = index
        self._cap = None
        self._jpeg = b""
        self._pos = 0
        self._ready = False

    def _open(self):
        import cv2

        if self._cap is None:
            self._cap = cv2.VideoCapture(self._index)
            if not self._cap.isOpened():
                raise RuntimeError(f"cannot open webcam index {self._index}")
        return self._cap

    # ---- frame.camera.* ----

    def power_save(self, *_a) -> None:
        pass

    def capture(self, args: object = None) -> None:
        import cv2
        import numpy as np

        cap = self._open()
        ok, frame = cap.read()
        if not ok:
            raise RuntimeError("webcam read failed")

        # Match the SDK contract: even resolution, 100..720, square image.
        resolution = int(_opt(args, "resolution", 512)) or 512
        resolution = max(100, min(720, resolution))
        resolution -= resolution % 2
        quality = str(_opt(args, "quality", "MEDIUM"))

        h, w = frame.shape[:2]
        side = min(h, w)
        frame = frame[(h - side) // 2:(h - side) // 2 + side,
                      (w - side) // 2:(w - side) // 2 + side]
        frame = cv2.resize(frame, (resolution, resolution), interpolation=cv2.INTER_AREA)
        # firmware's sensor is mounted 90 deg CW; RxPhoto rotates -90 to correct.
        frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)

        q = _JPEG_QUALITY.get(quality, 50)
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, q])
        if not ok:
            raise RuntimeError("jpeg encode failed")
        self._jpeg = np.asarray(buf, dtype=np.uint8).tobytes()
        self._pos = 0
        self._ready = True
        _log.info("camera: %dx%d %s jpeg, %d bytes", resolution, resolution, quality, len(self._jpeg))

    def image_ready(self) -> bool:
        return self._ready

    def _read_from(self, start: int, n: int) -> str | None:
        n = int(n)
        if self._pos < start:
            self._pos = start
        if self._pos >= len(self._jpeg):
            self._ready = False
            return None
        chunk = self._jpeg[self._pos:self._pos + n]
        self._pos += len(chunk)
        return chunk.decode("latin-1")

    def read(self, n) -> str | None:
        # full JPEG, header included (SDK non-raw path)
        return self._read_from(0, n)

    def read_raw(self, n) -> str | None:
        # JPEG minus the fixed 623-byte header (SDK raw path re-prepends it)
        return self._read_from(623, n)

    def set_shutter(self, *_a) -> None:
        pass

    def set_gain(self, *_a) -> None:
        pass

    def set_white_balance(self, *_a) -> None:
        pass

    def auto(self, *_a):
        return None  # Frame-only auto-exposure; Halo path skips it

    def close(self) -> None:
        if self._cap is not None:
            try:
                self._cap.release()
            except Exception:  # noqa: BLE001
                pass
            self._cap = None


# --------------------------------------------------------------------- factory


class MediaConfig:
    """Parsed --mic / --speaker / --camera options."""

    def __init__(
        self,
        *,
        mic: str | int | None | bool = False,
        speaker: str | int | None | bool = False,
        camera: int | None | bool = False,
    ) -> None:
        self.mic = mic
        self.speaker = speaker
        self.camera = camera

    @property
    def any(self) -> bool:
        return self.mic is not False or self.speaker is not False or self.camera is not False

    def build(self) -> dict[str, object]:
        out: dict[str, object] = {}
        if self.mic is not False:
            out["mic"] = MicBridge(None if self.mic is True else self.mic)
        if self.speaker is not False:
            out["speaker"] = SpeakerBridge(None if self.speaker is True else self.speaker)
        if self.camera is not False:
            idx = 0 if self.camera is True or self.camera is None else int(self.camera)
            out["camera"] = CameraBridge(idx)
        return out
