// LSM6DS3TR-C sample source for the XIAO nRF52840 Sense.
// Talks to the onboard IMU directly over Wire1 (no extra library).
// The IMU has its own power pin, so it is fully off between sessions.

#ifdef ARDUINO_Seeed_XIAO_nRF52840_Sense

#include <Arduino.h>
#include <Wire.h>

#include "sample_source.h"

namespace {

constexpr uint8_t IMU_ADDR = 0x6A;

constexpr uint8_t REG_WHO_AM_I = 0x0F;
constexpr uint8_t REG_CTRL1_XL = 0x10;
constexpr uint8_t REG_CTRL2_G = 0x11;
constexpr uint8_t REG_CTRL3_C = 0x12;
constexpr uint8_t REG_OUTX_L_G = 0x22;  // gyro x/y/z, then accel x/y/z

constexpr uint8_t WHO_AM_I_VALUE = 0x6A;

// ODR 208 Hz (faster than the 100 Hz read rate, so each read gets a fresh
// sample at most ~5 ms old). Accel +-16 g, gyro +-2000 dps.
constexpr uint8_t CTRL1_XL_ON = 0x54;   // ODR 208 Hz, FS 16 g
constexpr uint8_t CTRL2_G_ON = 0x5C;    // ODR 208 Hz, FS 2000 dps
constexpr uint8_t CTRL3_C_INIT = 0x44;  // BDU, register auto-increment
constexpr uint8_t CTRL_OFF = 0x00;      // power-down

// Gyro needs ~70 ms after power-up before its output settles.
constexpr uint32_t POWER_UP_MS = 80;

bool ok = false;

bool writeReg(uint8_t reg, uint8_t value) {
    Wire1.beginTransmission(IMU_ADDR);
    Wire1.write(reg);
    Wire1.write(value);
    return Wire1.endTransmission() == 0;
}

bool readRegs(uint8_t reg, uint8_t* buf, uint8_t len) {
    Wire1.beginTransmission(IMU_ADDR);
    Wire1.write(reg);
    if (Wire1.endTransmission(false) != 0) return false;
    if (Wire1.requestFrom(IMU_ADDR, len) != len) return false;
    for (uint8_t i = 0; i < len; i++) buf[i] = Wire1.read();
    return true;
}

// Release the I2C pins before cutting IMU power, so the nRF's pull-ups
// don't back-power the chip through SDA/SCL.
void powerDown() {
    Wire1.end();
    pinMode(PIN_WIRE1_SDA, INPUT);
    pinMode(PIN_WIRE1_SCL, INPUT);
    digitalWrite(PIN_LSM6DS3TR_C_POWER, LOW);
}

int16_t le16(const uint8_t* p) {
    return (int16_t)(p[0] | (p[1] << 8));
}

}  // namespace

void sampleSourceBegin() {
    pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
    // The IMU is powered straight from this pin; use high drive like Seeed does.
    NRF_GPIO_Type* port = (g_ADigitalPinMap[PIN_LSM6DS3TR_C_POWER] >= 32) ? NRF_P1 : NRF_P0;
    port->PIN_CNF[g_ADigitalPinMap[PIN_LSM6DS3TR_C_POWER] & 31] |=
        GPIO_PIN_CNF_DRIVE_H0H1 << GPIO_PIN_CNF_DRIVE_Pos;
    digitalWrite(PIN_LSM6DS3TR_C_POWER, LOW);
    pinMode(PIN_WIRE1_SDA, INPUT);
    pinMode(PIN_WIRE1_SCL, INPUT);
}

void sampleSourceStart() {
    digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
    delay(10);  // boot time
    Wire1.begin();
    Wire1.setClock(400000);

    uint8_t who = 0;
    ok = readRegs(REG_WHO_AM_I, &who, 1) && who == WHO_AM_I_VALUE
        && writeReg(REG_CTRL3_C, CTRL3_C_INIT)
        && writeReg(REG_CTRL1_XL, CTRL1_XL_ON)
        && writeReg(REG_CTRL2_G, CTRL2_G_ON);
    if (!ok) {
        Serial.printf("[imu] init failed (WHO_AM_I=0x%02X), sending zeros\n", who);
        return;
    }
    delay(POWER_UP_MS);
}

void sampleSourceStop() {
    if (ok) {
        writeReg(REG_CTRL1_XL, CTRL_OFF);
        writeReg(REG_CTRL2_G, CTRL_OFF);
    }
    ok = false;
    powerDown();
}

void sampleSourceRead(ImuSample& s) {
    uint8_t raw[12];
    if (!ok || !readRegs(REG_OUTX_L_G, raw, sizeof(raw))) {
        s = {0, 0, 0, 0, 0, 0};
        return;
    }
    // Gyro: 70 mdps/LSB at 2000 dps -> 0.1 deg/s units is raw * 7 / 10.
    s.gx = (int16_t)(le16(raw + 0) * 7 / 10);
    s.gy = (int16_t)(le16(raw + 2) * 7 / 10);
    s.gz = (int16_t)(le16(raw + 4) * 7 / 10);
    // Accel: 0.488 mg/LSB at 16 g -> milli-g is raw * 61 / 125.
    s.ax = (int16_t)(le16(raw + 6) * 61 / 125);
    s.ay = (int16_t)(le16(raw + 8) * 61 / 125);
    s.az = (int16_t)(le16(raw + 10) * 61 / 125);
}

#endif
