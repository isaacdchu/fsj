#pragma once
// Where IMU samples come from. The BLE code only uses these functions.
// The build picks one implementation by board: sample_source_lsm6ds3.cpp on
// the XIAO nRF52840 Sense, sample_source_sim.cpp (fake jumps) on the plain board.

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
