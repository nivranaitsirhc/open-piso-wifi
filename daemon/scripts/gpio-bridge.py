#!/usr/bin/env python3
"""Board-neutral GPIO bridge for OpenPisoWifi.

libgpiod is the automatic backend for non-Raspberry-Pi SBCs. gpiozero/lgpio
remains available for Raspberry Pi and explicitly selected legacy setups.
"""

import json
import os
import select
import signal
import sys
from datetime import timedelta


def log(message):
    sys.stderr.write(f"[GPIO-BRIDGE] {message}\n")
    sys.stderr.flush()


def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def board_model():
    try:
        with open("/proc/device-tree/model", "rb") as model_file:
            return model_file.read().replace(b"\x00", b"").decode(errors="replace").strip()
    except OSError:
        return "Unknown Linux SBC"


MODEL = board_model()
IS_RASPBERRY_PI = "raspberry pi" in MODEL.lower()
REQUESTED_BACKEND = os.environ.get("GPIO_BACKEND", "auto").lower().strip()
GPIO_CHIP = os.environ.get("GPIO_CHIP", "/dev/gpiochip0")

# Only the Raspberry-compatible backend uses this mapping. Orange Pi and
# other SBCs use GPIO character-device line offsets, never physical pin/BCM
# translation.
PHYSICAL_TO_BCM = {
    3: 2, 5: 3, 7: 4, 8: 14, 10: 15, 11: 17, 12: 18, 13: 27,
    15: 22, 16: 23, 18: 24, 19: 10, 21: 9, 22: 25, 23: 11, 24: 8,
    26: 7, 29: 5, 31: 6, 32: 12, 33: 13, 35: 19, 36: 16, 37: 26,
    38: 20, 40: 21,
}
BCM_TO_PHYSICAL = {value: key for key, value in PHYSICAL_TO_BCM.items()}


def resolve_raspberry_pin(value):
    if value in PHYSICAL_TO_BCM:
        return PHYSICAL_TO_BCM[value], value
    return value, BCM_TO_PHYSICAL.get(value, value)


def backend_candidates():
    if REQUESTED_BACKEND in ("gpiod", "lgpio", "gpiozero"):
        return [REQUESTED_BACKEND]
    if REQUESTED_BACKEND not in ("", "auto"):
        raise RuntimeError(f"Unsupported GPIO_BACKEND={REQUESTED_BACKEND!r}")
    # Never silently apply Raspberry Pi BCM semantics to an unknown SBC.
    return ["lgpio", "gpiod"] if IS_RASPBERRY_PI else ["gpiod"]


def require_gpiod_lines():
    coin_line = os.environ.get("GPIO_COIN_LINE")
    inhibit_line = os.environ.get("GPIO_INHIBIT_LINE")
    if coin_line is None or inhibit_line is None:
        raise RuntimeError(
            "GPIO_COIN_LINE and GPIO_INHIBIT_LINE are required for gpiod; "
            "discover offsets with gpioinfo and configure the target board"
        )
    return int(coin_line), int(inhibit_line)


class GpiodV1Input:
    def __init__(self, chip_path, offset):
        import gpiod
        self.gpiod = gpiod
        self.chip = gpiod.Chip(chip_path)
        self.line = self.chip.get_line(offset)
        self.line.request(
            consumer="openpiso-coin",
            type=gpiod.LINE_REQ_EV_BOTH_EDGES,
            flags=gpiod.LINE_REQ_FLAG_BIAS_PULL_UP,
        )
        self.when_pressed = None
        self.when_released = None

    @property
    def is_pressed(self):
        return self.line.get_value() == 0

    def poll(self):
        if not self.line.event_wait(sec=0):
            return
        event = self.line.event_read()
        if event.event_type == self.gpiod.LineEvent.FALLING_EDGE:
            if self.when_pressed:
                self.when_pressed()
        elif event.event_type == self.gpiod.LineEvent.RISING_EDGE:
            if self.when_released:
                self.when_released()

    def close(self):
        self.line.release()
        self.chip.close()


class GpiodV1Output:
    def __init__(self, chip_path, offset, initial):
        import gpiod
        self.chip = gpiod.Chip(chip_path)
        self.line = self.chip.get_line(offset)
        self.line.request(consumer="openpiso-inhibit", type=gpiod.LINE_REQ_DIR_OUT, default_vals=[initial])
        self._value = int(initial)

    @property
    def value(self):
        return self._value

    @value.setter
    def value(self, value):
        self._value = int(value)
        self.line.set_value(self._value)

    def close(self):
        self.line.release()
        self.chip.close()


class GpiodV2Input:
    def __init__(self, chip_path, offset):
        import gpiod
        self.gpiod = gpiod
        self.offset = offset
        self.chip = gpiod.Chip(chip_path)
        line = gpiod.line
        self.request = self.chip.request_lines(
            consumer="openpiso-coin",
            config={offset: line.LineSettings(
                direction=line.Direction.INPUT,
                edge_detection=line.Edge.BOTH,
                bias=line.Bias.PULL_UP,
            )},
        )
        self.when_pressed = None
        self.when_released = None

    @property
    def is_pressed(self):
        return self.request.get_value(self.offset) == self.gpiod.line.Value.INACTIVE

    def poll(self):
        if not self.request.wait_edge_events(timedelta(seconds=0)):
            return
        for event in self.request.read_edge_events():
            event_type = getattr(event.event_type, "name", str(event.event_type)).upper()
            if "FALLING" in event_type:
                if self.when_pressed:
                    self.when_pressed()
            elif "RISING" in event_type:
                if self.when_released:
                    self.when_released()

    def close(self):
        self.request.release()
        self.chip.close()


class GpiodV2Output:
    def __init__(self, chip_path, offset, initial):
        import gpiod
        self.gpiod = gpiod
        self.offset = offset
        self.chip = gpiod.Chip(chip_path)
        line = gpiod.line
        self.request = self.chip.request_lines(
            consumer="openpiso-inhibit",
            config={offset: line.LineSettings(
                direction=line.Direction.OUTPUT,
                output_value=line.Value.ACTIVE if initial else line.Value.INACTIVE,
            )},
        )
        self._value = int(initial)

    @property
    def value(self):
        return self._value

    @value.setter
    def value(self, value):
        self._value = int(value)
        self.request.set_value(
            self.offset,
            self.gpiod.line.Value.ACTIVE if self._value else self.gpiod.line.Value.INACTIVE,
        )

    def close(self):
        self.request.release()
        self.chip.close()


def make_gpiod_devices(initial_level):
    import gpiod
    coin_line, inhibit_line = require_gpiod_lines()
    # libgpiod v1 exposes Chip.get_line; v2 uses request_lines/LineSettings.
    if hasattr(gpiod.Chip, "get_line"):
        coin = GpiodV1Input(GPIO_CHIP, coin_line)
        inhibit = GpiodV1Output(GPIO_CHIP, inhibit_line, initial_level)
    else:
        coin = GpiodV2Input(GPIO_CHIP, coin_line)
        inhibit = GpiodV2Output(GPIO_CHIP, inhibit_line, initial_level)
    return coin, inhibit, coin_line, inhibit_line


RAW_COIN = int(sys.argv[1]) if len(sys.argv) > 1 else 7
RAW_INHIBIT = int(sys.argv[2]) if len(sys.argv) > 2 else 11
INHIBIT_ACTIVE_HIGH = sys.argv[3].lower() == "true" if len(sys.argv) > 3 else True
INITIAL_LEVEL = 1 if INHIBIT_ACTIVE_HIGH else 0
coin = None
inhibit = None
backend = None
coin_identifier = None
inhibit_identifier = None


def close_devices():
    for device in (inhibit, coin):
        try:
            if device:
                device.close()
        except Exception:
            pass


def initialize_devices():
    global coin, inhibit, backend, coin_identifier, inhibit_identifier
    errors = []
    for candidate in backend_candidates():
        try:
            if candidate == "gpiod":
                coin_device, inhibit_device, coin_id, inhibit_id = make_gpiod_devices(INITIAL_LEVEL)
                coin_label = os.environ.get("GPIO_COIN_LABEL", f"line {coin_id}")
                inhibit_label = os.environ.get("GPIO_INHIBIT_LABEL", f"line {inhibit_id}")
            else:
                from gpiozero import Button, DigitalOutputDevice, Device
                from gpiozero.pins.lgpio import LGPIOFactory
                Device.pin_factory = LGPIOFactory()
                coin_id, coin_label = resolve_raspberry_pin(RAW_COIN)
                inhibit_id, inhibit_label = resolve_raspberry_pin(RAW_INHIBIT)
                inhibit_device = DigitalOutputDevice(
                    inhibit_id, active_high=True, initial_value=(INITIAL_LEVEL == 1)
                )
                inhibit_device.value = INITIAL_LEVEL
                coin_device = Button(coin_id, pull_up=True, bounce_time=0.015)
            coin = coin_device
            inhibit = inhibit_device
            backend = candidate
            coin_identifier = (coin_id, coin_label)
            inhibit_identifier = (inhibit_id, inhibit_label)
            return
        except Exception as error:
            close_devices()
            coin = None
            inhibit = None
            errors.append(f"{candidate}: {error}")
    raise RuntimeError("; ".join(errors) or "no GPIO backend available")


def on_pulse_press():
    log(f"[EDGE FALLING] Coin pulse START on {coin_identifier[1]}!")
    sys.stdout.write("PULSE\n")
    sys.stdout.flush()


def on_pulse_release():
    log(f"[EDGE RISING] Coin pulse END on {coin_identifier[1]}.")


try:
    initialize_devices()
    coin.when_pressed = on_pulse_press
    coin.when_released = on_pulse_release
except Exception as error:
    log(f"Failed to initialize GPIO: {error}")
    emit({"status": "error", "error": str(error), "boardModel": MODEL})
    sys.exit(1)

ready = {
    "status": "ready", "backend": backend, "boardModel": MODEL,
    "gpioChip": GPIO_CHIP if backend == "gpiod" else None,
    "coinPin": coin_identifier[1], "inhibitPin": inhibit_identifier[1],
    "activeHigh": INHIBIT_ACTIVE_HIGH, "inhibitLevel": INITIAL_LEVEL,
}
if backend == "gpiod":
    ready.update({"coinLine": coin_identifier[0], "inhibitLine": inhibit_identifier[0]})
else:
    ready.update({"coinBcm": coin_identifier[0], "inhibitBcm": inhibit_identifier[0]})
emit(ready)

try:
    idle_state = "LOW (0V / PRESSED)" if coin.is_pressed else "HIGH (3.3V IDLE)"
    log(f"GPIO initialized: {coin_identifier[1]} idle state is {idle_state}.")
except Exception as error:
    log(f"GPIO status read failed: {error}")


def cleanup(*_args):
    log("Cleaning up GPIO pins...")
    close_devices()
    sys.exit(0)


signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)

while True:
    if backend == "gpiod":
        coin.poll()
        readable, _, _ = select.select([sys.stdin], [], [], 0.05)
        if not readable:
            continue
    line = sys.stdin.readline()
    if not line:
        break
    parts = line.strip().lower().split()
    if not parts:
        continue
    command = parts[0]
    if command == "enable":
        target = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else (0 if INHIBIT_ACTIVE_HIGH else 1)
        inhibit.value = target
        emit({"event": "inhibit", "state": "enabled", "level": int(inhibit.value)})
    elif command in ("disable", "block"):
        target = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else (1 if INHIBIT_ACTIVE_HIGH else 0)
        inhibit.value = target
        emit({"event": "inhibit", "state": "blocked", "level": int(inhibit.value)})
    elif command == "set_mode" and len(parts) > 1:
        INHIBIT_ACTIVE_HIGH = parts[1] in ("true", "1")
        emit({"event": "mode_updated", "activeHigh": INHIBIT_ACTIVE_HIGH})
    elif command == "status":
        emit({"status": "online", "backend": backend, "boardModel": MODEL,
              "coinLevel": int(coin.is_pressed), "inhibitLevel": int(inhibit.value),
              "activeHigh": INHIBIT_ACTIVE_HIGH})
    elif command == "quit":
        break

cleanup()
