// FSJ skate firmware: BLE peripheral that streams IMU samples to the iPhone.
// One board per skate. Same firmware on both; SKATE_SIDE picks the name.
// The phone's Start/Stop buttons write CMD_START/CMD_STOP to the control
// characteristic (see protocol.h); the board only samples in between.
//   left:  arduino-cli compile ... (default)
//   right: arduino-cli compile ... --build-property "compiler.cpp.extra_flags=-DSKATE_SIDE=1"

#include <bluefruit.h>

#include "protocol.h"
#include "sample_source.h"

#ifndef SKATE_SIDE
#define SKATE_SIDE SIDE_RIGHT
#endif

const char* const DEVICE_NAME = (SKATE_SIDE == SIDE_RIGHT) ? "FSJ-R" : "FSJ-L";

const uint8_t SERVICE_UUID[16] = FSJ_UUID(0x01);
const uint8_t DATA_UUID[16] = FSJ_UUID(0x02);
const uint8_t INFO_UUID[16] = FSJ_UUID(0x03);
const uint8_t CONTROL_UUID[16] = FSJ_UUID(0x04);

constexpr uint32_t BATTERY_INTERVAL_MS = 30000;
constexpr uint32_t STATS_INTERVAL_MS = 5000;

BLEService fsjService(SERVICE_UUID);
BLECharacteristic dataChar(DATA_UUID);
BLECharacteristic infoChar(INFO_UUID);
BLECharacteristic controlChar(CONTROL_UUID);
BLEDis bledis;
BLEBas blebas;

DataPacket packet;
uint8_t fill = 0;
uint16_t seq = 0;
uint32_t nextSampleUs = 0;
bool streaming = false;

// Set from BLE callbacks (SoftDevice task), read in loop().
volatile bool startRequested = false;  // last command from the phone was CMD_START

uint32_t packetsSent = 0;
uint32_t packetsDropped = 0;
uint32_t lastBatteryMs = 0;
uint32_t lastStatsMs = 0;

// ---- battery ----------------------------------------------------------------

// XIAO: VBAT -> 1M / 510k divider -> PIN_VBAT, enabled by VBAT_ENABLE LOW.
// VBAT_ENABLE is kept LOW permanently: driving it HIGH while the battery
// is above 3.3 V can put more than VDD on the ADC pin (see Seeed wiki).
float readBatteryVolts() {
    uint32_t raw = analogRead(PIN_VBAT);  // 12-bit, 3.6 V internal reference
    return raw * 3.6f / 4096.0f * (1510.0f / 510.0f);
}

// Rough linear LiPo estimate. Good enough for a "charge me" indicator.
uint8_t readBatteryPercent() {
    float v = readBatteryVolts();
    float pct = (v - 3.3f) / (4.2f - 3.3f) * 100.0f;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    return (uint8_t)pct;
}

// ---- BLE --------------------------------------------------------------------

void onConnect(uint16_t connHandle) {
    BLEConnection* conn = Bluefruit.Connection(connHandle);
    char central[32] = {0};
    conn->getPeerName(central, sizeof(central));
    Serial.printf("connected to %s\n", central);

    // Ask for a bigger MTU so a whole DataPacket fits in one notification,
    // plus 2M PHY / longer data length for throughput (iOS may decline).
    conn->requestPHY();
    conn->requestDataLengthUpdate();
    conn->requestMtuExchange(247);
}

void onDisconnect(uint16_t connHandle, uint8_t reason) {
    (void)connHandle;
    startRequested = false;  // never keep sampling with no phone listening
    Serial.printf("disconnected, reason 0x%02X\n", reason);
}

void onControlWrite(uint16_t connHandle, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
    (void)connHandle;
    (void)chr;
    if (len < 1) return;
    switch (data[0]) {
        case CMD_START: startRequested = true;  break;
        case CMD_STOP:  startRequested = false; break;
        default: Serial.printf("unknown command 0x%02X\n", data[0]); break;
    }
}

void startAdvertising() {
    Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
    Bluefruit.Advertising.addTxPower();
    Bluefruit.Advertising.addService(fsjService);  // 128-bit UUID fills most of it
    Bluefruit.ScanResponse.addName();

    Bluefruit.Advertising.restartOnDisconnect(true);
    // Apple-recommended: 20 ms for the first 30 s, then 152.5 ms (units of 0.625 ms).
    Bluefruit.Advertising.setInterval(32, 244);
    Bluefruit.Advertising.setFastTimeout(30);
    Bluefruit.Advertising.start(0);  // advertise forever
}

void setupBle() {
    Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);  // allows MTU up to 247
    Bluefruit.begin();
    Bluefruit.setTxPower(4);  // dBm; the boot and body attenuate a lot
    Bluefruit.setName(DEVICE_NAME);
    Bluefruit.Periph.setConnectCallback(onConnect);
    Bluefruit.Periph.setDisconnectCallback(onDisconnect);
    Bluefruit.Periph.setConnInterval(12, 24);  // 15-30 ms (units of 1.25 ms)

    bledis.setManufacturer("FSJ");
    bledis.setModel("XIAO nRF52840");
    bledis.begin();

    blebas.begin();
    blebas.write(readBatteryPercent());

    fsjService.begin();

    dataChar.setProperties(CHR_PROPS_NOTIFY);
    dataChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    dataChar.setFixedLen(sizeof(DataPacket));
    dataChar.begin();

    InfoPacket info = {FSJ_PROTOCOL_VERSION, SKATE_SIDE, SAMPLE_RATE_HZ,
        SAMPLES_PER_PACKET};
    infoChar.setProperties(CHR_PROPS_READ);
    infoChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
    infoChar.setFixedLen(sizeof(InfoPacket));
    infoChar.begin();
    infoChar.write(&info, sizeof(info));

    controlChar.setProperties(CHR_PROPS_READ | CHR_PROPS_WRITE);
    controlChar.setPermission(SECMODE_OPEN, SECMODE_OPEN);
    controlChar.setFixedLen(1);
    controlChar.setWriteCallback(onControlWrite);
    controlChar.begin();
    controlChar.write8(CMD_STOP);

    startAdvertising();
}

// True once the phone has pressed Start, is subscribed, and the MTU fits a
// whole packet. Bluefruit splits anything larger than MTU-3 into several
// notifications, which would break the one-packet-per-notification framing.
bool readyToStream() {
    if (!startRequested) return false;
    if (!Bluefruit.connected() || !dataChar.notifyEnabled()) return false;
    BLEConnection* conn = Bluefruit.Connection(Bluefruit.connHandle());
    return conn && conn->getMtu() >= sizeof(DataPacket) + 3;
}

void sendPacket() {
    packet.seq = seq++;
    if (dataChar.notify(&packet, sizeof(packet))) {
        packetsSent++;
    } else {
        packetsDropped++;  // no free TX buffer; the seq gap shows it on the phone
    }
}

// ---- main -------------------------------------------------------------------

void setup() {
    Serial.begin(115200);  // never wait for USB: the board runs on battery in the skate

    pinMode(VBAT_ENABLE, OUTPUT);
    digitalWrite(VBAT_ENABLE, LOW);
    analogReadResolution(12);

    setupBle();
    sampleSourceBegin();
    Serial.printf("%s advertising\n", DEVICE_NAME);
}

void loop() {
    uint32_t nowMs = millis();

    if (nowMs - lastBatteryMs >= BATTERY_INTERVAL_MS) {
        lastBatteryMs = nowMs;
        uint8_t pct = readBatteryPercent();
        blebas.write(pct);
        if (Bluefruit.connected()) blebas.notify(pct);
    }

    if (nowMs - lastStatsMs >= STATS_INTERVAL_MS) {
        lastStatsMs = nowMs;
        Serial.printf(
            "streaming=%d sent=%lu dropped=%lu batt=%.2fV\n",
            streaming,
            packetsSent,
            packetsDropped,
            readBatteryVolts()
        );
    }

    bool ready = readyToStream();
    if (ready != streaming) {
        streaming = ready;
        fill = 0;
        if (streaming) {
            seq = 0;
            sampleSourceStart();
            nextSampleUs = micros();
        } else {
            sampleSourceStop();  // a partly filled packet is dropped
        }
        controlChar.write8(streaming ? CMD_START : CMD_STOP);
        Serial.println(streaming ? "streaming started" : "streaming stopped");
    }
    if (!streaming) {
        delay(10);  // yield to the BLE stack and let the CPU sleep
        return;
    }

    if ((int32_t)(micros() - nextSampleUs) >= 0) {
        if (fill == 0) packet.t0_us = nextSampleUs;
        sampleSourceRead(packet.samples[fill++]);
        nextSampleUs += SAMPLE_PERIOD_US;
        if (fill == SAMPLES_PER_PACKET) {
            sendPacket();
            fill = 0;
        }
    }
}
