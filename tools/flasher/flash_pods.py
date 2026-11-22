#!/usr/bin/env python3
"""FSJ pod flasher: pick a board, then flash it as the left or right skate.

The window lists the plugged-in XIAO nRF52840 boards in a dropdown. Once one is
picked, "Flash left" builds arduino/fsj with SKATE_SIDE=0 (advertises as FSJ-L)
and "Flash right" builds it with SKATE_SIDE=1 (FSJ-R), then uploads to that
board. The side is passed as a compiler flag, so fsj.ino is never edited.

Needs Python 3 with Tk 8.6 (python.org Python, or Homebrew Python plus
`brew install python-tk`; the macOS /usr/bin/python3 ships Tk 8.5, which can
draw a blank window) and arduino-cli with the Seeeduino:nrf52 core
installed. arduino-cli is found in this order: the ARDUINO_CLI environment
variable, PATH, then the copy bundled with Arduino IDE 2.

    python3 tools/flasher/flash_pods.py

Set FSJ_FQBN to build for another board, e.g.
FSJ_FQBN=Seeeduino:nrf52:xiaonRF52840 for the plain (no IMU) board.
"""

import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SKETCH_DIR = REPO_ROOT / "arduino" / "fsj"
FQBN = os.environ.get("FSJ_FQBN", "Seeeduino:nrf52:xiaonRF52840Sense")

SIDES = {
    "left": {"value": 0, "name": "FSJ-L"},
    "right": {"value": 1, "name": "FSJ-R"},
}

# Seeed's USB vendor id. The XIAO nRF52840 uses it both when running a sketch
# and in bootloader mode (double-tapped reset), with different product ids.
SEEED_VID = "0x2886"

BUNDLED_CLI_PATHS = [
    "/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli",
    os.path.expandvars(
        r"$LOCALAPPDATA\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe"
    ),
]


class FlashError(Exception):
    pass


def find_arduino_cli():
    env = os.environ.get("ARDUINO_CLI")
    if env and Path(env).is_file():
        return env
    on_path = shutil.which("arduino-cli")
    if on_path:
        return on_path
    for candidate in BUNDLED_CLI_PATHS:
        if Path(candidate).is_file():
            return candidate
    raise FlashError(
        "arduino-cli not found. Install Arduino IDE 2, put arduino-cli on PATH, "
        "or set ARDUINO_CLI to its path."
    )


def build_dir(side):
    # One build folder per side, so building one side never uploads the other's binary.
    return Path(tempfile.gettempdir()) / "fsj-build" / side


def compile_command(cli, side):
    flag = f"compiler.cpp.extra_flags=-DSKATE_SIDE={SIDES[side]['value']}"
    return [
        cli, "compile",
        "--fqbn", FQBN,
        "--build-property", flag,
        "--build-path", str(build_dir(side)),
        str(SKETCH_DIR),
    ]


def upload_command(cli, side, port):
    return [
        cli, "upload",
        "--fqbn", FQBN,
        "--input-dir", str(build_dir(side)),
        "-p", port,
        str(SKETCH_DIR),
    ]


def is_xiao(entry):
    """True if an arduino-cli `board list` entry looks like a XIAO nRF52840."""
    port = entry.get("port", {})
    props = port.get("properties", {}) or {}
    if (props.get("vid") or "").lower() == SEEED_VID:
        return True
    for board in entry.get("matching_boards", []) or []:
        if "nRF52840" in (board.get("name") or ""):
            return True
    return False


def list_xiao_ports(cli):
    """Serial ports of all plugged-in XIAO nRF52840 boards, as (address, label)."""
    result = subprocess.run(
        [cli, "board", "list", "--format", "json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise FlashError("arduino-cli board list failed:\n" + result.stderr.strip())
    data = json.loads(result.stdout or "[]")
    # arduino-cli 0.x prints a list; 1.x wraps it as {"detected_ports": [...]}.
    entries = data.get("detected_ports", []) if isinstance(data, dict) else data
    ports = []
    for entry in entries:
        port = entry.get("port", {})
        if port.get("protocol") != "serial" or not is_xiao(entry):
            continue
        address = port["address"]
        props = port.get("properties", {}) or {}
        serial = props.get("serialNumber")
        label = address + (f"  (serial {serial})" if serial else "")
        ports.append((address, label))
    return ports


class FlasherApp:
    PLACEHOLDER = "Pick a board..."

    def __init__(self, root):
        import tkinter as tk
        from tkinter import scrolledtext, ttk

        self.root = root
        self.events = queue.Queue()
        self.busy = False
        self.ports = []  # (address, label) from the last scan

        root.title("FSJ pod flasher")
        root.minsize(520, 380)

        board_row = tk.Frame(root)
        board_row.pack(fill="x", padx=12, pady=(12, 0))
        tk.Label(board_row, text="Board:").pack(side="left")
        self.board_var = tk.StringVar(value=self.PLACEHOLDER)
        self.board_box = ttk.Combobox(
            board_row, textvariable=self.board_var, state="readonly", values=[],
        )
        self.board_box.pack(side="left", expand=True, fill="x", padx=6)
        self.board_box.bind("<<ComboboxSelected>>", lambda _e: self.on_board_picked())
        self.refresh_btn = tk.Button(board_row, text="Refresh", command=self.refresh_ports)
        self.refresh_btn.pack(side="left")

        buttons = tk.Frame(root)
        buttons.pack(fill="x", padx=12, pady=12)
        self.left_btn = tk.Button(
            buttons, text="Flash left", height=2,
            command=lambda: self.start("left"),
        )
        self.right_btn = tk.Button(
            buttons, text="Flash right", height=2,
            command=lambda: self.start("right"),
        )
        self.left_btn.pack(side="left", expand=True, fill="x", padx=(0, 6))
        self.right_btn.pack(side="left", expand=True, fill="x", padx=(6, 0))

        self.status = tk.Label(root, text="", anchor="w", justify="left", wraplength=500)
        self.status.pack(fill="x", padx=12)

        self.log = scrolledtext.ScrolledText(root, height=16, state="disabled")
        self.log.pack(fill="both", expand=True, padx=12, pady=(6, 12))

        self.update_controls()
        root.after(100, self.drain_events)
        self.refresh_ports()

    # ---- UI helpers (main thread only) --------------------------------------

    def append_log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def selected_port(self):
        label = self.board_var.get()
        for address, port_label in self.ports:
            if port_label == label:
                return address
        return None

    def update_controls(self):
        # The side buttons only work once a board is picked.
        side_state = "normal" if not self.busy and self.selected_port() else "disabled"
        self.left_btn.configure(state=side_state)
        self.right_btn.configure(state=side_state)
        self.refresh_btn.configure(state="disabled" if self.busy else "normal")
        self.board_box.configure(state="disabled" if self.busy else "readonly")

    def set_busy(self, busy):
        self.busy = busy
        self.update_controls()

    def on_board_picked(self):
        self.status.configure(text="Now pick the side for this board.")
        self.update_controls()

    def show_ports(self, ports):
        # Keep the current pick if that board is still plugged in. Never pick
        # one automatically, so the user always chooses the board first.
        previous = self.selected_port()
        self.ports = ports
        self.board_box.configure(values=[label for _, label in ports])
        keep = [label for address, label in ports if address == previous]
        self.board_var.set(keep[0] if keep else self.PLACEHOLDER)
        if not ports:
            self.status.configure(
                text="No board found. Plug a pod in with a data USB cable, then press Refresh."
            )
        elif not keep:
            self.status.configure(text="Pick a board, then pick its side.")
        self.update_controls()

    def drain_events(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self.append_log(payload)
                elif kind == "status":
                    self.status.configure(text=payload)
                elif kind == "ports":
                    self.show_ports(payload)
                elif kind == "done":
                    self.set_busy(False)
        except queue.Empty:
            pass
        self.root.after(100, self.drain_events)

    # ---- background work ----------------------------------------------------

    def emit(self, kind, payload):
        self.events.put((kind, payload))

    def refresh_ports(self):
        if self.busy:
            return
        self.set_busy(True)
        self.status.configure(text="Looking for boards...")
        threading.Thread(target=self.scan_ports, daemon=True).start()

    def scan_ports(self):
        try:
            self.emit("ports", list_xiao_ports(find_arduino_cli()))
        except Exception as e:
            self.emit("ports", [])
            self.emit("status", str(e))
        finally:
            self.emit("done", None)

    def start(self, side):
        port = self.selected_port()
        if self.busy or port is None:
            return
        self.set_busy(True)
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        threading.Thread(target=self.flash, args=(side, port), daemon=True).start()

    def run(self, cmd):
        self.emit("log", "$ " + " ".join(f'"{c}"' if " " in c else c for c in cmd) + "\n")
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        for line in proc.stdout:
            self.emit("log", line)
        proc.wait()
        return proc.returncode

    def flash(self, side, port):
        name = SIDES[side]["name"]
        try:
            cli = find_arduino_cli()

            self.emit("status", f"Building {side} firmware ({name})...")
            if self.run(compile_command(cli, side)) != 0:
                raise FlashError("Build failed. See the log below.")

            self.emit("status", f"Uploading {name} to {port}...")
            if self.run(upload_command(cli, side, port)) != 0:
                raise FlashError(
                    "Upload failed. Double-tap the pod's reset button (the LED pulses), "
                    "press Refresh, pick the board again and retry."
                )
            self.emit("status", f"Done. The board on {port} is now the {side} skate ({name}).")
        except FlashError as e:
            self.emit("status", str(e))
        except Exception as e:  # keep the window usable whatever goes wrong
            self.emit("status", f"Error: {e}")
        finally:
            self.emit("done", None)


def main():
    try:
        import tkinter as tk
    except ImportError:
        sys.exit(
            "tkinter is missing. Use the python.org Python, or with Homebrew run "
            "`brew install python-tk`."
        )
    root = tk.Tk()
    FlasherApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
