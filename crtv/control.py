from __future__ import annotations

import json
import socket
import threading
from pathlib import Path

from .config import AppConfig
from .controller import TvController


class ControlServer:
    def __init__(self, config: AppConfig, controller: TvController):
        self.config = config
        self.controller = controller
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._serve, name="crtv-control", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.2)
                client.connect(str(self.config.control_socket))
                client.sendall(b"\n")
        except OSError:
            pass
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        try:
            self.config.control_socket.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

    def _serve(self) -> None:
        socket_path = self.config.control_socket
        socket_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            socket_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(socket_path))
            socket_path.chmod(0o600)
            server.listen()
            server.settimeout(0.5)
            while not self._stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                with conn:
                    try:
                        payload = conn.recv(4096).decode("utf-8").strip()
                    except OSError:
                        continue
                    if not payload:
                        continue
                    response = self._dispatch(payload)
                    try:
                        conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
                    except OSError:
                        continue

    def _dispatch(self, payload: str) -> dict[str, object]:
        command = payload.strip().lower()
        if command == "standby on":
            status = self.controller.enter_standby()
        elif command == "standby off":
            status = self.controller.exit_standby()
        elif command == "standby toggle":
            status = self.controller.toggle_standby()
        elif command == "standby status":
            status = self.controller.standby_status()
        else:
            return {"ok": False, "error": f"unsupported command: {payload}"}
        return {"ok": True, **status}


def send_control_command(socket_path: Path, command: str) -> dict[str, object]:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2.0)
            client.connect(str(socket_path))
            client.sendall((command.strip() + "\n").encode("utf-8"))
            raw = client.recv(4096).decode("utf-8").strip()
    except OSError as exc:
        raise RuntimeError(
            f"control socket unavailable at {socket_path}; is the crtv service running?"
        ) from exc
    if not raw:
        raise RuntimeError("empty response from control socket")
    response = json.loads(raw)
    if not response.get("ok"):
        raise RuntimeError(str(response.get("error", "control command failed")))
    return response
