#!/usr/bin/env python3
"""FSJ pod flasher: a two-button window that builds and uploads the skate firmware.

"Flash left" builds arduino/fsj with SKATE_SIDE=0 (advertises as FSJ-L) and
"Flash right" builds it with SKATE_SIDE=1 (FSJ-R), then uploads to a plugged-in
XIAO nRF52840. The side is passed as a compiler flag, so fsj.ino is never edited.

Needs Python 3 with tkinter (the macOS /usr/bin/python3 has it; with Homebrew
Python, `brew install python-tk`) and arduino-cli with the Seeeduino:nrf52 core
installed. arduino-cli is found in this order: the ARDUINO_CLI environment
variable, PATH, then the copy bundled with Arduino IDE 2.

    python3 tools/flasher/flash_pods.py

Set FSJ_FQBN to build for another board, e.g.
FSJ_FQBN=Seeeduino:nrf52:xiaonRF52840Sense for the Sense boards.
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
FQBN = os.environ.get("FSJ_FQBN", "Seeeduino:nrf52:xiaonRF52840")

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
    def __init__(self, root):
        import tkinter as tk
        from tkinter import scrolledtext

        self.tk = tk
        self.root = root
        self.events = queue.Queue()
        self.busy = False

        root.title("FSJ pod flasher")
        root.minsize(520, 360)

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

        self.status = tk.Label(root, text="Plug in a pod and pick its side.", anchor="w")
        self.status.pack(fill="x", padx=12)

        self.log = scrolledtext.ScrolledText(root, height=16, state="disabled")
        self.log.pack(fill="both", expand=True, padx=12, pady=(6, 12))

        root.after(100, self.drain_events)

    # ---- UI helpers (main thread only) --------------------------------------

    def append_log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text)
        self.log.see("end")
        self.log.configure(state="disabled")

    def set_busy(self, busy):
        self.busy = busy
        state = "disabled" if busy else "normal"
        self.left_btn.configure(state=state)
        self.right_btn.configure(state=state)

    def drain_events(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self.append_log(payload)
                elif kind == "status":
                    self.status.configure(text=payload)
                elif kind == "pick_port":
                    side, ports, reply = payload
                    reply.put(self.ask_port(side, ports))
                elif kind == "done":
                    self.set_busy(False)
        except queue.Empty:
            pass
        self.root.after(100, self.drain_events)

    def ask_port(self, side, ports):
        """Modal list of ports when more than one board is plugged in. Returns an address or None."""
        tk = self.tk
        dialog = tk.Toplevel(self.root)
        dialog.title("Choose a port")
        dialog.transient(self.root)
        dialog.grab_set()
        tk.Label(
            dialog,
            justify="left",
            text=(
                f"{len(ports)} pods are plugged in. Pick the {side} one.\n"
                "Not sure? Unplug the other pod and try again."
            ),
        ).pack(padx=12, pady=(12, 6), anchor="w")
        listbox = tk.Listbox(dialog, height=len(ports), width=50)
        for _, label in ports:
            listbox.insert("end", label)
        listbox.selection_set(0)
        listbox.pack(padx=12, fill="x")

        choice = {"address": None}

        def ok():
            sel = listbox.curselection()
            if sel:
                choice["address"] = ports[sel[0]][0]
            dialog.destroy()

        row = tk.Frame(dialog)
        row.pack(pady=12)
        tk.Button(row, text="Flash", command=ok).pack(side="left", padx=6)
        tk.Button(row, text="Cancel", command=dialog.destroy).pack(side="left", padx=6)
        listbox.bind("<Double-Button-1>", lambda _e: ok())
        self.root.wait_window(dialog)
        return choice["address"]

    # ---- flashing (worker thread) -------------------------------------------

    def start(self, side):
        if self.busy:
            return
        self.set_busy(True)
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")
        threading.Thread(target=self.flash, args=(side,), daemon=True).start()

    def emit(self, kind, payload):
        self.events.put((kind, payload))

    def run(self, cmd):
        self.emit("log", "$ " + " ".join(f'"{c}"' if " " in c else c for c in cmd) + "\n")
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        for line in proc.stdout:
            self.emit("log", line)
        proc.wait()
        return proc.returncode

    def pick_port(self, cli, side):
        ports = list_xiao_ports(cli)
        if not ports:
            raise FlashError(
                "No XIAO nRF52840 found. Plug the pod in with a data USB cable. "
                "If it still doesn't show up, double-tap its reset button and try again."
            )
        if len(ports) == 1:
            return ports[0][0]
        reply = queue.Queue()
        self.emit("pick_port", (side, ports, reply))
        return reply.get()

    def flash(self, side):
        name = SIDES[side]["name"]
        try:
            cli = find_arduino_cli()

            self.emit("status", f"Building {side} firmware ({name})...")
            if self.run(compile_command(cli, side)) != 0:
                raise FlashError("Build failed. See the log above.")

            self.emit("status", "Looking for the pod...")
            port = self.pick_port(cli, side)
            if port is None:
                self.emit("status", "Cancelled.")
                return

            self.emit("status", f"Uploading {name} to {port}...")
            if self.run(upload_command(cli, side, port)) != 0:
                raise FlashError(
                    "Upload failed. Double-tap the pod's reset button (the LED pulses) "
                    "and try again."
                )
            self.emit("status", f"Done. This pod is now the {side} skate ({name}).")
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
            "tkinter is missing. Use /usr/bin/python3, or with Homebrew Python run "
            "`brew install python-tk`."
        )
    root = tk.Tk()
    FlasherApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
