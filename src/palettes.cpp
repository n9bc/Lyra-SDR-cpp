// Lyra — color palettes.  See palettes.h.  Ported from
// lyra/ui/palettes.py (+ an added "Amber").

#include "palettes.h"

#include <algorithm>
#include <utility>
#include <vector>

namespace lyra::palettes {

namespace {

struct Stop { double pos; int r, g, b; };

// Linear-interpolate a 256-entry RGB LUT from (pos, rgb) stops —
// the C++ analogue of palettes.py::_build().
Lut build(const std::vector<Stop> &stops) {
    Lut out{};
    for (int i = 0; i < 256; ++i) {
        const double t = i / 255.0;
        // Find the bracketing stops.
        const Stop *a = &stops.front();
        const Stop *b = &stops.back();
        for (size_t k = 0; k + 1 < stops.size(); ++k) {
            if (t >= stops[k].pos && t <= stops[k + 1].pos) {
                a = &stops[k];
                b = &stops[k + 1];
                break;
            }
        }
        double f = 0.0;
        if (b->pos > a->pos) {
            f = (t - a->pos) / (b->pos - a->pos);
        }
        auto lerp = [f](int x, int y) {
            return static_cast<unsigned char>(
                std::clamp(static_cast<int>(x + (y - x) * f + 0.5), 0, 255));
        };
        out[i] = { lerp(a->r, b->r), lerp(a->g, b->g), lerp(a->b, b->b) };
    }
    return out;
}

struct Registry {
    QStringList names;
    std::vector<Lut> luts;
};

const Registry &registry() {
    static const Registry reg = [] {
        Registry r;
        auto add = [&](const char *name, std::vector<Stop> stops) {
            r.names << QString::fromUtf8(name);
            r.luts.push_back(build(std::move(stops)));
        };
        // Order matches palettes.py (Classic default), Amber appended.
        add("Classic", {
            {0.00,   4,   8,  16}, {0.15,  10,  24,  60}, {0.35,  20,  80, 180},
            {0.55,  30, 180, 220}, {0.75, 230, 220, 120}, {0.90, 240, 100,  40},
            {1.00, 255,  80,  80} });
        add("Inferno", {
            {0.00,   0,   0,   4}, {0.20,  40,  11,  84}, {0.40, 101,  21, 110},
            {0.60, 159,  42,  99}, {0.75, 212,  72,  66}, {0.87, 245, 125,  21},
            {0.95, 250, 193,  39}, {1.00, 252, 255, 164} });
        add("Viridis", {
            {0.00,  68,   1,  84}, {0.25,  59,  82, 139}, {0.50,  33, 145, 140},
            {0.75,  94, 201,  98}, {1.00, 253, 231,  37} });
        add("Plasma", {
            {0.00,  13,   8, 135}, {0.20,  84,   2, 163}, {0.40, 156,  23, 158},
            {0.60, 218,  57, 105}, {0.80, 249, 149,  63}, {1.00, 240, 249,  33} });
        add("Rainbow", {
            {0.00,   0,   0,   0}, {0.15,   0,   0, 128}, {0.30,   0, 128, 255},
            {0.45,   0, 255, 128}, {0.60, 255, 255,   0}, {0.80, 255, 128,   0},
            {1.00, 255,   0,   0} });
        add("Ocean", {
            {0.00,   0,   0,   0}, {0.25,   8,  25,  64}, {0.50,  18,  95, 130},
            {0.75,  80, 200, 220}, {1.00, 230, 245, 255} });
        add("Night", {
            {0.00,   0,   0,   0}, {0.30,  40,   0,   0}, {0.60, 130,  10,  10},
            {0.85, 220,  80,  30}, {1.00, 255, 180,  60} });
        add("Grayscale", {
            {0.00,   0,   0,   0}, {1.00, 255, 255, 255} });
        // Amber — warm deskHPSDR look (new; not in old Lyra).
        add("Amber", {
            {0.00,  12,   6,   0}, {0.35,  90,  40,   0}, {0.65, 200, 110,  10},
            {0.85, 245, 175,  40}, {1.00, 255, 230, 130} });
        // Observatory — the neon 5-stop ramp shared with the macOS
        // frontend (LyraDesignSystem.swift spectrum stops; mirrored in
        // LyraDS.palette.spectrumStops).  Keep the values byte-identical.
        add("Observatory", {
            {0.00,  46, 107, 255}, {0.30,   0, 229, 255}, {0.55, 139,  92, 246},
            {0.80, 255,  43, 214}, {1.00, 255, 210,  63} });
        return r;
    }();
    return reg;
}

} // namespace

const QStringList &names() { return registry().names; }

const Lut &lut(int index) {
    const Registry &reg = registry();
    if (index < 0 || index >= static_cast<int>(reg.luts.size())) {
        index = 0;
    }
    return reg.luts[static_cast<size_t>(index)];
}

} // namespace lyra::palettes
