#pragma once
// BLE protocol shared between the skate firmware and the iOS app.
// All multi-byte fields are little-endian (native on both nRF52 and iOS).

#include <stdint.h>

#define FSJ_PROTOCOL_VERSION 3

// 128-bit UUIDs (strings for the iOS side / nRF Connect):
//   service  3c820001-3646-49c3-9e01-da24fa4a5faa
//   data     3c820002-3646-49c3-9e01-da24fa4a5faa   notify, DataPacket
//   info     3c820003-3646-49c3-9e01-da24fa4a5faa   read,   InfoPacket
//   control  3c820004-3646-49c3-9e01-da24fa4a5faa   read + write (with response), 1 byte ControlCommand
//   sync     3c820005-3646-49c3-9e01-da24fa4a5faa   write (without response) + notify, SyncReply
//
// Session: the phone connects and subscribes to `data` once. Nothing is
// sampled until it writes CMD_START to `control`; the board then powers the
// IMU, restarts `seq` at 0 and streams until CMD_STOP or a disconnect.
// Reading `control` returns the current state (CMD_START while streaming).
//
// Clock sync: the phone and each board have their own clocks. The phone
// writes a 1-byte ping id to `sync`; the board immediately notifies a
// SyncReply with that id and its micros() at the moment the ping arrived.
// The phone takes the midpoint of its send and receive times as the moment
// the board read its clock, and keeps the ping with the shortest round trip.
// It pings before Start and after Stop, which also measures clock drift, and
// then converts every DataPacket.t0_us to phone time.
//
// Bluefruit wants the bytes in little-endian order; `id` is the 16-bit
// field that differs between them.
#define FSJ_UUID(id) \
    { 0xaa, 0x5f, 0x4a, 0xfa, 0x24, 0xda, 0x01, 0x9e, \
      0xc3, 0x49, 0x46, 0x36, (id), 0x00, 0x82, 0x3c }

constexpr uint16_t SAMPLE_RATE_HZ = 100;
constexpr uint8_t SAMPLES_PER_PACKET = 10;
constexpr uint32_t SAMPLE_PERIOD_US = 1000000UL / SAMPLE_RATE_HZ;

enum ControlCommand : uint8_t {
    CMD_STOP = 0x00,
    CMD_START = 0x01
};

enum SkateSide : uint8_t {
    SIDE_LEFT = 0,
    SIDE_RIGHT = 1
};

// One IMU reading. Units chosen to fit int16 with headroom for an LSM6DS3
// at ±16 g / ±2000 dps.
struct __attribute__((packed)) ImuSample {
    int16_t ax, ay, az;  // milli-g
    int16_t gx, gy, gz;  // 0.1 deg/s
};

// Payload of the data characteristic. Sent as exactly one notification;
// the firmware doesn't send until the ATT MTU is big enough to hold it.
struct __attribute__((packed)) DataPacket {
    uint16_t seq;    // increments per packet; gaps mean dropped packets
    uint32_t t0_us;  // board micros() of samples[0]; wraps every ~71.6 min
    ImuSample samples[SAMPLES_PER_PACKET];  // spaced SAMPLE_PERIOD_US apart
};

// Notified on the sync characteristic in reply to a ping.
struct __attribute__((packed)) SyncReply {
    uint8_t id;     // the ping id the phone wrote
    uint32_t t_us;  // board micros() when the ping arrived (same clock as t0_us)
};

// Payload of the info characteristic.
struct __attribute__((packed)) InfoPacket {
    uint8_t version;  // FSJ_PROTOCOL_VERSION
    uint8_t side;     // SkateSide
    uint16_t sample_rate_hz;
    uint8_t samples_per_packet;
};

static_assert(sizeof(ImuSample) == 12, "ImuSample layout changed");
static_assert(sizeof(DataPacket) == 126, "DataPacket layout changed");
static_assert(sizeof(InfoPacket) == 5, "InfoPacket layout changed");
static_assert(sizeof(SyncReply) == 5, "SyncReply layout changed");
