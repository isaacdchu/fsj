// Simulated IMU for the plain XIAO nRF52840 (no IMU on board).
// Produces gliding noise with a fake jump every few seconds:
//   glide -> takeoff spike -> free fall + spin (airtime) -> landing spike.
// The true simulated airtime goes to USB serial so the phone's measurement
// can be checked against it.

#include <Arduino.h>

#include "sample_source.h"

namespace {

enum class Phase {
    Glide,
    Takeoff,
    Air,
    Landing
};

Phase phase = Phase::Glide;
uint32_t ticksLeft = 0;
int16_t spin = 0;  // 0.1 deg/s, about the vertical axis while airborne

uint32_t msToTicks(uint32_t ms) {
    return ms * SAMPLE_RATE_HZ / 1000;
}

int16_t noise(int16_t amp) {
    return (int16_t)random(-amp, amp + 1);
}

void enter(Phase p) {
    phase = p;
    switch (p) {
        case Phase::Glide:
            ticksLeft = msToTicks(random(3000, 8000));
            break;
        case Phase::Takeoff:
            ticksLeft = msToTicks(60);
            spin = (int16_t)random(12000, 20000);  // 1200-2000 deg/s
            break;
        case Phase::Air: {
            uint32_t airMs = random(350, 651);
            ticksLeft = msToTicks(airMs);
            Serial.printf(
                "[sim] jump: airtime %lu ms\n",
                ticksLeft * 1000UL / SAMPLE_RATE_HZ
            );
            break;
        }
        case Phase::Landing:
            ticksLeft = msToTicks(40);
            break;
    }
}

}  // namespace

void sampleSourceBegin() {
    randomSeed(analogRead(A0) ^ micros());
    enter(Phase::Glide);
}

void sampleSourceRead(ImuSample& s) {
    switch (phase) {
        case Phase::Glide:  // ~1 g on z plus skating vibration
            s = {noise(80), noise(80), (int16_t)(1000 + noise(60)),
                noise(300), noise(300), noise(400)};
            break;
        case Phase::Takeoff:
            s = {noise(400), noise(400), (int16_t)(2500 + noise(400)),
                noise(800), noise(800), (int16_t)(spin / 2)};
            break;
        case Phase::Air:  // free fall: accelerometer reads ~0 g
            s = {noise(60), noise(60), noise(60),
                noise(300), noise(300), (int16_t)(spin + noise(500))};
            break;
        case Phase::Landing:
            s = {noise(1000), noise(1000), (int16_t)(4000 + noise(1000)),
                noise(1500), noise(1500), (int16_t)(spin / 3)};
            break;
    }

    if (ticksLeft > 0) ticksLeft--;
    if (ticksLeft == 0) {
        switch (phase) {
            case Phase::Glide:   enter(Phase::Takeoff); break;
            case Phase::Takeoff: enter(Phase::Air);     break;
            case Phase::Air:     enter(Phase::Landing); break;
            case Phase::Landing: enter(Phase::Glide);   break;
        }
    }
}
