#pragma once
// BLE protocol shared between the skate firmware and the iOS app.
// All multi-byte fields are little-endian (native on both nRF52 and iOS).

#include <stdint.h>

#define FSJ_PROTOCOL_VERSION 1

// 128-bit UUIDs (strings for the iOS side / nRF Connect):
//   service  3c820001-3646-49c3-9e01-da24fa4a5faa
//   data     3c820002-3646-49c3-9e01-da24fa4a5faa   notify, DataPacket
//   info     3c820003-3646-49c3-9e01-da24fa4a5faa   read,   InfoPacket
// Bluefruit wants the bytes in little-endian order; `id` is the 16-bit
// field that differs between them.
#define FSJ_UUID(id) \
    { 0xaa, 0x5f, 0x4a, 0xfa, 0x24, 0xda, 0x01, 0x9e, \
      0xc3, 0x49, 0x46, 0x36, (id), 0x00, 0x82, 0x3c }

constexpr uint16_t SAMPLE_RATE_HZ = 100;
constexpr uint8_t SAMPLES_PER_PACKET = 10;
constexpr uint32_t SAMPLE_PERIOD_US = 1000000UL / SAMPLE_RATE_HZ;

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
