// Lyra — panadapter peak-label math (pure, Qt-light).
//
// Turns a detected spectrum peak's on-screen position into the audio
// frequency it lands on in the receiver, and formats that for the label.
// The panadapter centre (fraction 0.5) is the zero-beat / suppressed-carrier
// point and its passband edges are Hz offsets from centre, so a peak's audio
// frequency is simply its distance from centre -- magnitude, so it is
// mode-independent (USB/LSB/CW/AM) and immune to the HL2 spectral reversal.
// Kept out of the Qt Quick item so it unit-tests standalone
// (scratch/test_panadapter_peakmath.cpp).
#pragma once

#include <QString>

namespace lyra {

// Audio frequency (Hz) of a peak at screen fraction `frac` (0..1 across the
// panadapter width) for a display `spanHz`.  |(frac - 0.5) * spanHz|; 0 when
// spanHz <= 0 (engine stopped / not yet sized).
double peakAudioHz(double frac, double spanHz) noexcept;

// The peak label text for an audio frequency `hz`: below 1000, the nearest
// 10 Hz as "NNN Hz"; at or above 1000, one decimal as "N.N kHz".
QString formatPeakHz(double hz);

}  // namespace lyra
