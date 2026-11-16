# fsj

## Flashing the MCU

The firmware in `arduino/fsj/` runs on a Seeed XIAO nRF52840. It builds with the
Seeeduino nRF52 core (`Seeeduino:nrf52`, v1.1.13). Install that core through the
Arduino IDE Boards Manager first.

### Flasher app

`tools/flasher/flash_pods.py` is a small window with two buttons, Flash left
and Flash right. Each one builds the firmware for that side (it passes
`SKATE_SIDE` as a compiler flag, so `fsj.ino` is never edited) and uploads it to
the plugged-in pod. If both pods are plugged in, it asks which port to use.

It needs the Seeeduino nRF52 core installed (steps 1 to 3 below) and
`arduino-cli`, which it finds on `PATH` or inside Arduino IDE 2. Run it with the
macOS system Python, which includes tkinter:

```bash
/usr/bin/python3 tools/flasher/flash_pods.py
```

Set `FSJ_FQBN=Seeeduino:nrf52:xiaonRF52840Sense` to build for the Sense boards.

### Arduino IDE setup

1. Open Arduino IDE > Settings and add this to "Additional boards manager URLs":
   `https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json`
2. In Boards Manager, search `seeed nrf52` and install "Seeed nRF52 Boards"
   version 1.1.13. Do not install "Seeed nRF52 mbed-enabled Boards"; the sketch
   will not compile with it.
3. macOS only: the core calls `python`, but macOS only has `python3`, so
   compiling fails with `exec: "python": executable file not found in $PATH`.
   Create `~/Library/Arduino15/packages/Seeeduino/hardware/nrf52/1.1.13/platform.local.txt`
   with this line, then restart the IDE:

   ```
   recipe.objcopy.uf2.pattern=/usr/bin/python3 "{runtime.platform.path}/tools/uf2conv/uf2_wrap.py" "{runtime.platform.path}/tools/uf2conv/uf2conv.py" "{build.board}" "{build.path}" "{build.source.path}" "{build.project_name}"
   ```

   Reinstalling or updating the core may delete this file.
4. Open `arduino/fsj/fsj.ino`.
5. Select Tools > Board > Seeed nRF52 Boards > Seeed XIAO nRF52840 (the Sense
   variant once those boards arrive).
6. Plug in the board and select it under Tools > Port.
7. Click Upload. The serial monitor uses 115200 baud.

The IDE builds the left skate (`FSJ-L`) by default. To build the right skate,
change `#define SKATE_SIDE SIDE_LEFT` in `fsj.ino` to `SIDE_RIGHT` before
uploading, and change it back afterwards.

If the upload fails or no port shows up, double-tap the reset button to put the
board in bootloader mode (the LED pulses), select the new port, and upload
again.

### arduino-cli

`arduino-cli` comes bundled with Arduino IDE 2:

```bash
# macOS
CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"

# Windows (Git Bash)
CLI="$LOCALAPPDATA/Programs/Arduino IDE/resources/app/lib/backend/resources/arduino-cli.exe"
```

Compile for the left or right skate (`SKATE_SIDE` defaults to left):

```bash
# left skate
"$CLI" compile --fqbn Seeeduino:nrf52:xiaonRF52840 arduino/fsj

# right skate
"$CLI" compile --fqbn Seeeduino:nrf52:xiaonRF52840 --build-property "compiler.cpp.extra_flags=-DSKATE_SIDE=1" arduino/fsj
```

Plug in the board over USB, find its port, then upload. `upload` flashes the
most recent compile, so compile for the side you want right before uploading:

```bash
"$CLI" board list

# macOS port looks like /dev/cu.usbmodemXXXX, Windows looks like COMx
"$CLI" upload --fqbn Seeeduino:nrf52:xiaonRF52840 -p <port> arduino/fsj
```

Open the serial monitor (the sketch uses 115200 baud):

```bash
"$CLI" monitor -p <port> -c baudrate=115200
```

When the XIAO nRF52840 Sense boards arrive, use the
`Seeeduino:nrf52:xiaonRF52840Sense` FQBN in place of
`Seeeduino:nrf52:xiaonRF52840`.
