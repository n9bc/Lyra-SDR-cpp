// Lyra — panadapter peak-label math.  See panadapter_peakmath.h.
#include "panadapter_peakmath.h"

#include <cmath>

namespace lyra {

double peakAudioHz(double frac, double spanHz) noexcept
{
    if (!(spanHz > 0.0)) return 0.0;
    return std::fabs((frac - 0.5) * spanHz);
}

QString formatPeakHz(double hz)
{
    // Below 1 kHz: nearest 10 Hz as "NNN Hz".  At/above: one-decimal "N.N kHz".
    if (hz < 1000.0) {
        const long rounded = std::lround(hz / 10.0) * 10;
        return QString::number(rounded) + QStringLiteral(" Hz");
    }
    return QString::number(hz / 1000.0, 'f', 1) + QStringLiteral(" kHz");
}

}  // namespace lyra
