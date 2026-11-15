# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A device for measuring how long a figure skater is in the air on jumps. Each skate gets a Seeed XIAO nRF52840 in an enclosure on the bottom of the boot, running on a rechargeable battery inside the enclosure. Both boards connect to an iPhone 15 Pro over Bluetooth LE. So the system is two independent BLE peripherals (left and right skate) and one central (the iPhone).

Design constraints that follow from this:
- **Battery-powered and sealed:** power use matters (BLE advertising/connection intervals, sensor sampling rates, sleep). USB serial is only there during bench development. Don't make firmware wait on `Serial` in code meant to run on the skate.
- **Two boards running the same firmware:** each skate has to be identifiable (left or right) so the phone can pair the right data with the right foot and line up timing across both boards.
- **iOS central:** the BLE design has to work within CoreBluetooth limits (no Classic BT, MTU/connection intervals set by iOS, background restrictions).

## Layout

Firmware lives in `arduino/fsj/`:
- `protocol.h`: the BLE contract with the iOS app (UUIDs, `DataPacket`/`InfoPacket` byte layouts, sample rate). Keep the iOS parser in sync with it, and bump `FSJ_PROTOCOL_VERSION` when the layout changes.
- `fsj.ino`: the Bluefruit peripheral. It advertises as `FSJ-L` or `FSJ-R`. The phone subscribes to the data characteristic on connect, then writes 1 (start) or 0 (stop) to the control characteristic; the board only samples between the two and stops by itself on disconnect. Each 126-byte packet is one notification. Bluefruit splits anything larger than MTU−3 into several notifications, so the firmware waits until the MTU is at least 129 before streaming. It also runs the standard Battery and Device Information services.
- `sample_source.h`: the data-source interface. `sample_source_sim.cpp` makes up jumps and prints the true airtime over serial. A real LSM6DS3 implementation will replace it on the Sense board.
- There's no iOS app in the repo yet.

## Current phase

The Bluetooth link comes first. Until the Sense boards arrive, firmware runs on the plain board and sends **random or simulated data** over BLE in place of IMU readings. Keep the data source behind a small interface so real IMU sampling can replace the fake data later without changing the BLE layer.

## Toolchain

- Board core: **Seeeduino nRF52 (`Seeeduino:nrf52`, v1.1.13)**. This is the Adafruit nRF52 / Bluefruit-based core (it uses `Adafruit_TinyUSB.h` and Bluefruit for BLE). It is **not** the mbed-based core, so don't use `ArduinoBLE` or mbed APIs.
- FQBN: `Seeeduino:nrf52:xiaonRF52840` for now. The board in hand is the **plain** XIAO nRF52840, which has no IMU. The final hardware is the **XIAO nRF52840 Sense** (it has the onboard LSM6DS3TR-C IMU, which jump detection will use). It's on order. When it arrives, switch to `Seeeduino:nrf52:xiaonRF52840Sense`.
- `arduino-cli` is not on PATH. Arduino IDE 2 ships a copy of it:

```bash
CLI="$LOCALAPPDATA/Programs/Arduino IDE/resources/app/lib/backend/resources/arduino-cli.exe"

# compile the left skate (SKATE_SIDE defaults to left)
"$CLI" compile --fqbn Seeeduino:nrf52:xiaonRF52840 arduino/fsj

# compile the right skate
"$CLI" compile --fqbn Seeeduino:nrf52:xiaonRF52840 --build-property "compiler.cpp.extra_flags=-DSKATE_SIDE=1" arduino/fsj

# find the board's COM port, then upload
"$CLI" board list
"$CLI" upload --fqbn Seeeduino:nrf52:xiaonRF52840 -p COMx arduino/fsj

# serial monitor (sketch uses 115200)
"$CLI" monitor -p COMx -c baudrate=115200
```

There are no tests or linter. Compiling is the check that's available.

## Repo notes

- `.gitignore` contains `*.md`, so this file (and any new Markdown) isn't tracked by git unless that rule changes or the file is force-added.
