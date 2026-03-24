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
CHANNEL_ENCODER_PINS = {"a": 23, "b": 24, "sw": 25}

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
active_selection = None
desired_selection = None
last_started_selection = None

active_vibe_numbers = []
active_channels_by_vibe = {}
current_vibe = 0
current_channel = 0
selected_channel_by_vibe = {}
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


def load_active_layout():
    global active_vibe_numbers, active_channels_by_vibe

    with open(CHANNELS_FILE, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    vibes = payload.get("vibes", [])
    vibe_numbers = []
    channels_by_vibe = {}

    for vibe_index, vibe in enumerate(vibes, start=1):
        if not isinstance(vibe, dict) or vibe.get("disabled", False):
            continue

        vibe_number = vibe.get("number", vibe_index)
        if not isinstance(vibe_number, int):
            continue

        channel_numbers = []
        for channel_index, channel in enumerate(vibe.get("channels", []), start=1):
            if not isinstance(channel, dict) or channel.get("disabled", False):
                continue
            channel_number = channel.get("number", channel_index)
            if isinstance(channel_number, int):
                channel_numbers.append(channel_number)

        channel_numbers = sorted(set(channel_numbers))
        if not channel_numbers:
            continue

        vibe_numbers.append(vibe_number)
        channels_by_vibe[vibe_number] = channel_numbers

    vibe_numbers = sorted(set(vibe_numbers))
    if not vibe_numbers:
        raise RuntimeError("No active vibes found in channels.json")

    active_vibe_numbers = vibe_numbers
    active_channels_by_vibe = channels_by_vibe


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


def next_configured_channel(vibe, channel):
    channels = active_channels_by_vibe[vibe]
    for candidate in channels:
        if candidate > channel:
            return candidate
    return channels[0]


def prev_configured_channel(vibe, channel):
    channels = active_channels_by_vibe[vibe]
    for candidate in reversed(channels):
        if candidate < channel:
            return candidate
    return channels[-1]


def default_channel_for_vibe(vibe):
    remembered = selected_channel_by_vibe.get(vibe)
    channels = active_channels_by_vibe[vibe]
    if remembered in channels:
        return remembered
    return channels[0]


def build_switch_args(vibe, channel):
    return [
        CRT_PLAYER,
        "switch",
        "--vibe",
        str(vibe),
        "--channel",
        str(channel),
        "--no-recover",
    ]


def request_selection(vibe, channel=None):
    global current_vibe, current_channel, desired_selection

    if vibe not in active_channels_by_vibe:
        return

    if channel is None:
        channel = default_channel_for_vibe(vibe)
    elif channel not in active_channels_by_vibe[vibe]:
        channel = default_channel_for_vibe(vibe)

    with state_lock:
        current_vibe = vibe
        current_channel = channel
        selected_channel_by_vibe[vibe] = channel
        desired_selection = (vibe, channel)

    write_switch_request_token()
    print(f"{ts()}  TARGET VIBE {vibe} CHANNEL {channel}")


def next_vibe():
    if current_vibe not in active_vibe_numbers:
        request_selection(active_vibe_numbers[0])
        return
    request_selection(next_configured_vibe(current_vibe))


def prev_vibe():
    if current_vibe not in active_vibe_numbers:
        request_selection(active_vibe_numbers[-1])
        return
    request_selection(prev_configured_vibe(current_vibe))


def next_channel():
    if current_vibe not in active_channels_by_vibe:
        request_selection(active_vibe_numbers[0])
        return

    channel = current_channel
    if channel not in active_channels_by_vibe[current_vibe]:
        channel = default_channel_for_vibe(current_vibe)

    request_selection(current_vibe, next_configured_channel(current_vibe, channel))


def prev_channel():
    if current_vibe not in active_channels_by_vibe:
        request_selection(active_vibe_numbers[0])
        return

    channel = current_channel
    if channel not in active_channels_by_vibe[current_vibe]:
        channel = default_channel_for_vibe(current_vibe)

    request_selection(current_vibe, prev_configured_channel(current_vibe, channel))


def switch_worker():
    global active_process, active_selection, last_started_selection

    while True:
        completed_selection = None
        completed_rc = None
        completed_desired = None
        start_selection = None
        start_args = None

        with state_lock:
            proc = active_process
            desired = desired_selection
            active = active_selection

        if proc is not None:
            rc = proc.poll()
            if rc is not None:
                completed_selection = active
                completed_rc = rc
                completed_desired = desired
                with state_lock:
                    active_process = None
                    active_selection = None

        with state_lock:
            proc = active_process
            desired = desired_selection

            if proc is None and desired is not None and desired != last_started_selection:
                start_selection = desired
                start_args = build_switch_args(*desired)
                try:
                    active_process = subprocess.Popen(start_args)
                    active_selection = desired
                    last_started_selection = desired
                except Exception as exc:
                    print(f"{ts()}  Command error: {exc}")
                    active_process = None
                    active_selection = None

        if start_selection is not None and start_args is not None:
            print(f"{ts()}  RUN {' '.join(start_args)}")

        if completed_selection is not None:
            vibe, channel = completed_selection
            if completed_rc == 0:
                if completed_desired == completed_selection:
                    print(f"{ts()}  SWITCHED TO VIBE {vibe} CHANNEL {channel}")
                else:
                    print(
                        f"{ts()}  STALE SWITCH COMPLETED "
                        f"vibe={vibe} channel={channel} desired={completed_desired}"
                    )
            elif completed_rc == 2:
                print(f"{ts()}  SUPERSEDED SWITCH TO VIBE {vibe} CHANNEL {channel}")
            else:
                if completed_desired == completed_selection:
                    print(f"{ts()}  SWITCH FAILED TO VIBE {vibe} CHANNEL {channel} rc={completed_rc}")
                else:
                    print(
                        f"{ts()}  STALE SWITCH FAILED vibe={vibe} "
                        f"channel={channel} rc={completed_rc} desired={completed_desired}"
                    )

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
        print(
            f"{ts()}  {self.name:<8} {msg:<28} "
            f"A={a} B={b} vibe={current_vibe} ch={current_channel} acc={self.accumulator}"
        )

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


load_active_layout()
threading.Thread(target=switch_worker, daemon=True).start()

vibe_encoder = RotaryEncoder(
    name="vibe",
    pin_a_num=VIBE_ENCODER_PINS["a"],
    pin_b_num=VIBE_ENCODER_PINS["b"],
    pin_sw_num=VIBE_ENCODER_PINS["sw"],
    on_clockwise=next_vibe,
    on_counterclockwise=prev_vibe,
)

channel_encoder = RotaryEncoder(
    name="channel",
    pin_a_num=CHANNEL_ENCODER_PINS["a"],
    pin_b_num=CHANNEL_ENCODER_PINS["b"],
    pin_sw_num=CHANNEL_ENCODER_PINS["sw"],
    on_clockwise=next_channel,
    on_counterclockwise=prev_channel,
)

print("Encoder control started")
print(
    "Vibe encoder pins: "
    f"A={VIBE_ENCODER_PINS['a']} B={VIBE_ENCODER_PINS['b']} SW={VIBE_ENCODER_PINS['sw']}"
)
print(
    "Channel encoder pins: "
    f"A={CHANNEL_ENCODER_PINS['a']} B={CHANNEL_ENCODER_PINS['b']} SW={CHANNEL_ENCODER_PINS['sw']}"
)
print(f"Player path: {CRT_PLAYER}")
print(f"Vibes: {active_vibe_numbers}")
print(f"Channels by vibe: {active_channels_by_vibe}")
print(f"Detent transitions: {DETENT_TRANSITIONS}")

vibe_encoder.log("INITIAL")
channel_encoder.log("INITIAL")
request_selection(active_vibe_numbers[0])

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    print("\nExiting")
