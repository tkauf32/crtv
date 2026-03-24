#!/usr/bin/env python3

import json
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from gpiozero import Button

VIBE_ENCODER_PINS = {"a": 17, "b": 27, "sw": 22}
PROGRAM_ENCODER_PINS = {"a": 23, "b": 24, "sw": 25}

CRT_PLAYER = "/home/tommy/crtv/crt_player.sh"
CHANNELS_FILE = "/home/tommy/crtv/channels.json"
SWITCH_REQUEST_FILE = "/tmp/crt_player_switch.request"

BUTTON_BOUNCE = 0.05
PIN_BOUNCE = 0.001
DETENT_TRANSITIONS = 4
WORKER_POLL_SECONDS = 0.05
DETENT_COOLDOWN_SECONDS = 0.40

state_lock = threading.Lock()
active_process = None
active_vibe = None
desired_vibe = None
last_started_vibe = None

active_vibe_numbers = []
current_vibe = 0
start_time = time.time()

TRANSITIONS = {
    (0, 1): +1,
    (1, 3): +1,
    (3, 2): +1,
    (2, 0): +1,
    (1, 0): -1,
    (3, 1): -1,
    (2, 3): -1,
    (0, 2): -1,
}


def ts():
    return f"{time.time() - start_time:8.3f}s"


def write_switch_request_token():
    token = f"encoder-{uuid.uuid4()}"
    Path(SWITCH_REQUEST_FILE).write_text(token, encoding="utf-8")


def load_active_vibes():
    global active_vibe_numbers

    with open(CHANNELS_FILE, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    numbers = []
    for index, vibe in enumerate(payload.get("vibes", []), start=1):
        if not isinstance(vibe, dict) or vibe.get("disabled", False):
            continue
        vibe_number = vibe.get("number", index)
        if isinstance(vibe_number, int):
            numbers.append(vibe_number)

    numbers = sorted(set(numbers))
    if not numbers:
        raise RuntimeError("No active vibes found in channels.json")

    active_vibe_numbers = numbers


def next_configured_vibe(vibe):
    for candidate in active_vibe_numbers:
        if candidate > vibe:
            return candidate
    return active_vibe_numbers[0]


def prev_configured_vibe(vibe):
    for candidate in reversed(active_vibe_numbers):
        if candidate < vibe:
            return candidate
    return active_vibe_numbers[-1]


def build_vibe_switch_args(vibe):
    return [CRT_PLAYER, "switch", "--vibe", str(vibe), "--no-recover"]


def build_program_switch_args(vibe, direction):
    flag = "--program-next" if direction > 0 else "--program-prev"
    return [CRT_PLAYER, "switch", "--vibe", str(vibe), flag, "--no-recover"]


def request_vibe(vibe):
    global current_vibe, desired_vibe

    with state_lock:
        current_vibe = vibe
        desired_vibe = vibe

    write_switch_request_token()
    print(f"{ts()}  TARGET VIBE {vibe}")


def next_vibe():
    if current_vibe not in active_vibe_numbers:
        request_vibe(active_vibe_numbers[0])
        return
    request_vibe(next_configured_vibe(current_vibe))


def prev_vibe():
    if current_vibe not in active_vibe_numbers:
        request_vibe(active_vibe_numbers[-1])
        return
    request_vibe(prev_configured_vibe(current_vibe))


def request_program(direction):
    vibe = current_vibe
    if vibe not in active_vibe_numbers:
        print(f"{ts()}  PROGRAM {'NEXT' if direction > 0 else 'PREV'} IGNORED no active vibe")
        return

    args = build_program_switch_args(vibe, direction)
    write_switch_request_token()
    try:
        subprocess.Popen(args)
        print(f"{ts()}  RUN {' '.join(args)}")
    except Exception as exc:
        print(f"{ts()}  Command error: {exc}")


def switch_worker():
    global active_process, active_vibe, last_started_vibe

    while True:
        completed_vibe = None
        completed_rc = None
        completed_desired = None
        start_vibe = None
        start_args = None

        with state_lock:
            proc = active_process
            desired = desired_vibe
            active = active_vibe

        if proc is not None:
            rc = proc.poll()
            if rc is not None:
                completed_vibe = active
                completed_rc = rc
                completed_desired = desired
                with state_lock:
                    active_process = None
                    active_vibe = None

        with state_lock:
            proc = active_process
            desired = desired_vibe

            if proc is None and desired in active_vibe_numbers and desired != last_started_vibe:
                start_vibe = desired
                start_args = build_vibe_switch_args(desired)
                try:
                    active_process = subprocess.Popen(start_args)
                    active_vibe = desired
                    last_started_vibe = desired
                except Exception as exc:
                    print(f"{ts()}  Command error: {exc}")
                    active_process = None
                    active_vibe = None

        if start_vibe is not None and start_args is not None:
            print(f"{ts()}  RUN {' '.join(start_args)}")

        if completed_vibe is not None:
            if completed_rc == 0:
                if completed_desired == completed_vibe:
                    print(f"{ts()}  SWITCHED TO VIBE {completed_vibe}")
                else:
                    print(f"{ts()}  STALE SWITCH COMPLETED vibe={completed_vibe} desired={completed_desired}")
            elif completed_rc == 2:
                print(f"{ts()}  SUPERSEDED SWITCH TO VIBE {completed_vibe}")
            else:
                if completed_desired == completed_vibe:
                    print(f"{ts()}  SWITCH FAILED TO VIBE {completed_vibe} rc={completed_rc}")
                else:
                    print(f"{ts()}  STALE SWITCH FAILED vibe={completed_vibe} rc={completed_rc} desired={completed_desired}")

        time.sleep(WORKER_POLL_SECONDS)


@dataclass
class RotaryEncoder:
    name: str
    pin_a_num: int
    pin_b_num: int
    pin_sw_num: int
    on_clockwise: callable
    on_counterclockwise: callable

    def __post_init__(self):
        self.pin_a = Button(self.pin_a_num, pull_up=True, bounce_time=PIN_BOUNCE)
        self.pin_b = Button(self.pin_b_num, pull_up=True, bounce_time=PIN_BOUNCE)
        self.pin_sw = Button(self.pin_sw_num, pull_up=True, bounce_time=BUTTON_BOUNCE)
        self.accumulator = 0
        self.last_ab = self.ab_value()
        self.last_detent_time = 0.0

        self.pin_a.when_pressed = lambda: self.handle_ab_change("A LOW")
        self.pin_a.when_released = lambda: self.handle_ab_change("A HIGH")
        self.pin_b.when_pressed = lambda: self.handle_ab_change("B LOW")
        self.pin_b.when_released = lambda: self.handle_ab_change("B HIGH")
        self.pin_sw.when_pressed = self.handle_button_press

    def logic_level(self, btn):
        return 0 if btn.is_pressed else 1

    def ab_bits(self):
        a = self.logic_level(self.pin_a)
        b = self.logic_level(self.pin_b)
        return a, b

    def ab_value(self):
        a, b = self.ab_bits()
        return (a << 1) | b

    def log(self, msg):
        a, b = self.ab_bits()
        print(f"{ts()}  {self.name:<8} {msg:<28} A={a} B={b} vibe={current_vibe} acc={self.accumulator}")

    def handle_button_press(self):
        self.log("BUTTON PRESS IGNORED")

    def handle_ab_change(self, source):
        current_ab = self.ab_value()
        step = TRANSITIONS.get((self.last_ab, current_ab), 0)
        if step == 0:
            self.last_ab = current_ab
            return

        self.accumulator += step
        self.last_ab = current_ab

        if self.accumulator >= DETENT_TRANSITIONS:
            self.accumulator = 0
            now = time.time()
            if now - self.last_detent_time < DETENT_COOLDOWN_SECONDS:
                self.log("DETENT CW IGNORED")
                return
            self.last_detent_time = now
            self.log(f"DETENT CW {source}")
            self.on_clockwise()
        elif self.accumulator <= -DETENT_TRANSITIONS:
            self.accumulator = 0
            now = time.time()
            if now - self.last_detent_time < DETENT_COOLDOWN_SECONDS:
                self.log("DETENT CCW IGNORED")
                return
            self.last_detent_time = now
            self.log(f"DETENT CCW {source}")
            self.on_counterclockwise()


load_active_vibes()
threading.Thread(target=switch_worker, daemon=True).start()

vibe_encoder = RotaryEncoder(
    name="vibe",
    pin_a_num=VIBE_ENCODER_PINS["a"],
    pin_b_num=VIBE_ENCODER_PINS["b"],
    pin_sw_num=VIBE_ENCODER_PINS["sw"],
    on_clockwise=next_vibe,
    on_counterclockwise=prev_vibe,
)

program_encoder = RotaryEncoder(
    name="program",
    pin_a_num=PROGRAM_ENCODER_PINS["a"],
    pin_b_num=PROGRAM_ENCODER_PINS["b"],
    pin_sw_num=PROGRAM_ENCODER_PINS["sw"],
    on_clockwise=lambda: request_program(1),
    on_counterclockwise=lambda: request_program(-1),
)

print("Encoder control started")
print(
    "Vibe encoder pins: "
    f"A={VIBE_ENCODER_PINS['a']} B={VIBE_ENCODER_PINS['b']} SW={VIBE_ENCODER_PINS['sw']}"
)
print(
    "Program encoder pins: "
    f"A={PROGRAM_ENCODER_PINS['a']} B={PROGRAM_ENCODER_PINS['b']} SW={PROGRAM_ENCODER_PINS['sw']}"
)
print(f"Player path: {CRT_PLAYER}")
print(f"Vibes: {active_vibe_numbers}")
print(f"Detent transitions: {DETENT_TRANSITIONS}")

vibe_encoder.log("INITIAL")
program_encoder.log("INITIAL")
request_vibe(active_vibe_numbers[0])

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("\nExiting")
