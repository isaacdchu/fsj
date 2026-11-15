#pragma once
// Where IMU samples come from. The BLE code only uses these functions, so
// the simulator (sample_source_sim.cpp) can be replaced by a real LSM6DS3
// implementation on the XIAO nRF52840 Sense without touching fsj.ino.

#include "protocol.h"

// Once at boot. Leave the sensor powered down.
void sampleSourceBegin();

// The phone pressed Start: power the sensor up and get it sampling.
void sampleSourceStart();

// The phone pressed Stop or went away: power the sensor down.
void sampleSourceStop();

// Fill `out` with the next sample. Called once every SAMPLE_PERIOD_US
// between sampleSourceStart() and sampleSourceStop().
void sampleSourceRead(ImuSample& out);
