from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass

from .config import AppConfig
from .models import EncoderPins

try:
    from gpiozero import Button
except Exception:  # pragma: no cover - gpiozero is optional off-device
    Button = None  # type: ignore[assignment]


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


@dataclass
class RotaryCallbacks:
    on_clockwise: Callable[[], None]
    on_counterclockwise: Callable[[], None]
    on_click: Callable[[], None]


class RotaryEncoder:
    def __init__(
        self,
        name: str,
        pins: EncoderPins,
        config: AppConfig,
        callbacks: RotaryCallbacks,
    ):
        if Button is None:
            raise RuntimeError("gpiozero is required on the Raspberry Pi runtime")
        self.name = name
        self.callbacks = callbacks
        self.detent_transitions = config.detent_transitions
        self.detent_cooldown_seconds = config.detent_cooldown_seconds
        self.pin_a = Button(pins.a, pull_up=True, bounce_time=config.pin_bounce)
        self.pin_b = Button(pins.b, pull_up=True, bounce_time=config.pin_bounce)
        self.pin_sw = Button(pins.sw, pull_up=True, bounce_time=config.button_bounce)
        self.accumulator = 0
        self.last_ab = self._ab_value()
        self.last_detent_time = 0.0

        self.pin_a.when_pressed = lambda: self._handle_ab_change()
        self.pin_a.when_released = lambda: self._handle_ab_change()
        self.pin_b.when_pressed = lambda: self._handle_ab_change()
        self.pin_b.when_released = lambda: self._handle_ab_change()
        self.pin_sw.when_pressed = self.callbacks.on_click

    def _logic_level(self, button: Button) -> int:
        return 0 if button.is_pressed else 1

    def _ab_value(self) -> int:
        return (self._logic_level(self.pin_a) << 1) | self._logic_level(self.pin_b)

    def _handle_ab_change(self) -> None:
        current_ab = self._ab_value()
        step = TRANSITIONS.get((self.last_ab, current_ab), 0)
        self.last_ab = current_ab
        if step == 0:
            return

        self.accumulator += step
        if abs(self.accumulator) < self.detent_transitions:
            return

        now = time.time()
        if now - self.last_detent_time < self.detent_cooldown_seconds:
            self.accumulator = 0
            return

        direction = 1 if self.accumulator > 0 else -1
        self.accumulator = 0
        self.last_detent_time = now
        if direction > 0:
            self.callbacks.on_clockwise()
        else:
            self.callbacks.on_counterclockwise()


class InputRouter:
    def __init__(self, config: AppConfig, controller: "TvController"):
        from .controller import TvController

        self.left = RotaryEncoder(
            name="top",
            pins=config.top_encoder,
            config=config,
            callbacks=RotaryCallbacks(
                on_clockwise=controller.on_left_clockwise,
                on_counterclockwise=controller.on_left_counterclockwise,
                on_click=controller.on_left_click,
            ),
        )
        self.right = RotaryEncoder(
            name="bottom",
            pins=config.bottom_encoder,
            config=config,
            callbacks=RotaryCallbacks(
                on_clockwise=controller.on_right_clockwise,
                on_counterclockwise=controller.on_right_counterclockwise,
                on_click=controller.on_right_click,
            ),
        )
