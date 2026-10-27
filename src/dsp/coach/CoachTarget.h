// eSSB Coach foundation — the Qt-free pieces every analyzer/advisor stage
// shares: the 1/6-octave band layout, the target curves (with tolerance
// bands), the five tonal zones, mid-band normalisation, and a minimal JSON
// form of a Target so the model can keep custom targets in QSettings.
//
// Targets are expressed in dB relative to the 500-2000 Hz mean, so a measured
// curve is run through normalise() before being compared against one.
#pragma once

#include <string>
#include <vector>

namespace lyra::dsp::coach {

// 1/6-octave bands: centre = fromHz * 2^(k/6), edges = centre * 2^(+-1/12).
struct BandLayout {
    std::vector<double> centreHz, loHz, hiHz;
    int size() const { return static_cast<int>(centreHz.size()); }
};

BandLayout makeBands(double fromHz = 40.0, double toHz = 12000.0);

struct TargetPoint {
    double hz, db;
};

struct Target {
    std::string id, name;
    double lowEdgeHz = 0.0, highEdgeHz = 0.0;  // the passband the target covers
    std::vector<TargetPoint> points;           // ascending hz
    double tolLowDb = 3.0, tolDb = 3.0;        // tolerance below / above tolSplitHz
    double tolSplitHz = 150.0;
    bool builtin = false;
};

// Linear in log10(hz) between points; flat beyond the first/last point.
double targetDbAt(const Target &t, double hz);

// tolLowDb below tolSplitHz, tolDb at and above it.
double toleranceAt(const Target &t, double hz);

// essb, midfi, typical, am (in that order).
std::vector<Target> builtinTargets();

enum class ZoneId { Bass, LowMid, Body, Upper, Top };

struct Zone {
    ZoneId id;
    double loHz, hiHz;
};

// Top runs 3500 Hz -> targetHighEdgeHz.
std::vector<Zone> defaultZones(double targetHighEdgeHz);

// Shift so the mean dB of the bands centred in 500-2000 Hz is 0.
void normalise(std::vector<double> &bandDb, const BandLayout &bands);

// Hand-rolled minimal JSON for this one struct (keeps the module Qt-free).
std::string targetToJson(const Target &t);
bool targetFromJson(const std::string &json, Target &out);

}  // namespace lyra::dsp::coach
