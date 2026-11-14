#pragma once
// Where IMU samples come from. The BLE code only uses these two functions,
// so the simulator (sample_source_sim.cpp) can be replaced by a real
// LSM6DS3 implementation on the XIAO nRF52840 Sense without touching fsj.ino.

#include "protocol.h"

void sampleSourceBegin();

// Fill `out` with the next sample. Called once every SAMPLE_PERIOD_US.
void sampleSourceRead(ImuSample& out);
