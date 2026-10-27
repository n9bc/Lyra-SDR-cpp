#include "dsp/coach/CoachTarget.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <utility>

namespace lyra::dsp::coach {

namespace {

constexpr double kMidLoHz = 500.0;
constexpr double kMidHiHz = 2000.0;

Target make(const char *id, const char *name, double lo, double hi,
            std::vector<TargetPoint> pts, double tolLow, double tol)
{
    Target t;
    t.id = id;
    t.name = name;
    t.lowEdgeHz = lo;
    t.highEdgeHz = hi;
    t.points = std::move(pts);
    t.tolLowDb = tolLow;
    t.tolDb = tol;
    t.tolSplitHz = 150.0;
    t.builtin = true;
    return t;
}

// ---- JSON helpers -------------------------------------------------------

void putString(std::string &o, const std::string &s)
{
    o += '"';
    for (const unsigned char c : s) {
        switch (c) {
        case '"':  o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n";  break;
        case '\r': o += "\\r";  break;
        case '\t': o += "\\t";  break;
        default:
            if (c < 0x20) {
                char b[8];
                std::snprintf(b, sizeof b, "\\u%04x", c);
                o += b;
            } else {
                o += static_cast<char>(c);
            }
        }
    }
    o += '"';
}

void putNum(std::string &o, double v)
{
    char b[40];
    std::snprintf(b, sizeof b, "%.17g", v);  // round-trips a double exactly
    o += b;
}

struct Parser {
    const std::string &s;
    size_t i = 0;

    void ws() { while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i; }
    bool eat(char c) { ws(); if (i < s.size() && s[i] == c) { ++i; return true; } return false; }

    bool str(std::string &out)
    {
        if (!eat('"')) return false;
        out.clear();
        while (i < s.size() && s[i] != '"') {
            char c = s[i++];
            if (c == '\\') {
                if (i >= s.size()) return false;
                const char e = s[i++];
                switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    if (i + 4 > s.size()) return false;
                    char *end = nullptr;
                    const std::string hex = s.substr(i, 4);
                    const long cp = std::strtol(hex.c_str(), &end, 16);
                    if (end != hex.c_str() + 4 || cp > 0xFF) return false;  // we only emit < 0x20
                    out += static_cast<char>(cp);
                    i += 4;
                    break;
                }
                default: return false;
                }
            } else {
                out += c;
            }
        }
        if (i >= s.size()) return false;
        ++i;  // closing quote
        return true;
    }

    bool num(double &v)
    {
        ws();
        const char *b = s.c_str() + i;
        char *end = nullptr;
        v = std::strtod(b, &end);
        if (end == b) return false;
        i += static_cast<size_t>(end - b);
        return true;
    }

    bool boolean(bool &v)
    {
        ws();
        if (s.compare(i, 4, "true") == 0)  { v = true;  i += 4; return true; }
        if (s.compare(i, 5, "false") == 0) { v = false; i += 5; return true; }
        return false;
    }

    bool points(std::vector<TargetPoint> &out)
    {
        if (!eat('[')) return false;
        out.clear();
        if (eat(']')) return true;
        do {
            TargetPoint p{};
            if (!eat('[') || !num(p.hz) || !eat(',') || !num(p.db) || !eat(']')) return false;
            out.push_back(p);
        } while (eat(','));
        return eat(']');
    }
};

}  // namespace

BandLayout makeBands(double fromHz, double toHz)
{
    BandLayout b;
    const double e = std::pow(2.0, 1.0 / 12.0);
    for (int k = 0;; ++k) {
        const double c = fromHz * std::pow(2.0, k / 6.0);
        if (c > toHz * (1.0 + 1e-9)) break;
        b.centreHz.push_back(c);
        b.loHz.push_back(c / e);
        b.hiHz.push_back(c * e);
    }
    return b;
}

double targetDbAt(const Target &t, double hz)
{
    const auto &p = t.points;
    if (p.empty()) return 0.0;
    if (hz <= p.front().hz) return p.front().db;
    if (hz >= p.back().hz) return p.back().db;
    for (size_t k = 1; k < p.size(); ++k) {
        if (hz <= p[k].hz) {
            const double l0 = std::log10(p[k - 1].hz), l1 = std::log10(p[k].hz);
            const double f = (std::log10(hz) - l0) / (l1 - l0);
            return p[k - 1].db + f * (p[k].db - p[k - 1].db);
        }
    }
    return p.back().db;
}

double toleranceAt(const Target &t, double hz)
{
    return hz < t.tolSplitHz ? t.tolLowDb : t.tolDb;
}

std::vector<Target> builtinTargets()
{
    return {
        make("essb",    "eSSB",       50.0, 6000.0,
             {{50, 0}, {70, 3}, {150, 3}, {200, 0}, {6000, 0}}, 5.0, 3.0),
        make("midfi",   "Mid-fi",    100.0, 4000.0, {{100, 0}, {4000, 0}}, 3.0, 3.0),
        make("typical", "Typical",   300.0, 2700.0, {{300, 0}, {2700, 0}}, 3.0, 3.0),
        make("am",      "AM",         50.0, 9000.0, {{50, 0}, {9000, 0}},  3.0, 3.0),
    };
}

std::vector<Zone> defaultZones(double targetHighEdgeHz)
{
    return {
        {ZoneId::Bass,   60.0,   150.0},
        {ZoneId::LowMid, 150.0,  600.0},
        {ZoneId::Body,   600.0,  2000.0},
        {ZoneId::Upper,  2000.0, 3500.0},
        {ZoneId::Top,    3500.0, targetHighEdgeHz},
    };
}

void normalise(std::vector<double> &bandDb, const BandLayout &bands)
{
    double sum = 0.0;
    int n = 0;
    const int count = std::min<int>(bands.size(), static_cast<int>(bandDb.size()));
    for (int k = 0; k < count; ++k) {
        if (bands.centreHz[k] >= kMidLoHz && bands.centreHz[k] <= kMidHiHz) {
            sum += bandDb[k];
            ++n;
        }
    }
    if (n == 0) return;
    const double mean = sum / n;
    for (double &v : bandDb) v -= mean;
}

std::string targetToJson(const Target &t)
{
    std::string o = "{\"id\":";
    putString(o, t.id);
    o += ",\"name\":";
    putString(o, t.name);
    o += ",\"lowEdgeHz\":";   putNum(o, t.lowEdgeHz);
    o += ",\"highEdgeHz\":";  putNum(o, t.highEdgeHz);
    o += ",\"tolLowDb\":";    putNum(o, t.tolLowDb);
    o += ",\"tolDb\":";       putNum(o, t.tolDb);
    o += ",\"tolSplitHz\":";  putNum(o, t.tolSplitHz);
    o += ",\"builtin\":";     o += t.builtin ? "true" : "false";
    o += ",\"points\":[";
    for (size_t k = 0; k < t.points.size(); ++k) {
        if (k) o += ',';
        o += '[';
        putNum(o, t.points[k].hz);
        o += ',';
        putNum(o, t.points[k].db);
        o += ']';
    }
    o += "]}";
    return o;
}

bool targetFromJson(const std::string &json, Target &out)
{
    Parser p{json};
    Target t;
    bool gotId = false, gotPoints = false;
    if (!p.eat('{')) return false;
    if (!p.eat('}')) {
        do {
            std::string key;
            if (!p.str(key) || !p.eat(':')) return false;
            bool ok;
            if      (key == "id")         { ok = p.str(t.id); gotId = ok; }
            else if (key == "name")       ok = p.str(t.name);
            else if (key == "lowEdgeHz")  ok = p.num(t.lowEdgeHz);
            else if (key == "highEdgeHz") ok = p.num(t.highEdgeHz);
            else if (key == "tolLowDb")   ok = p.num(t.tolLowDb);
            else if (key == "tolDb")      ok = p.num(t.tolDb);
            else if (key == "tolSplitHz") ok = p.num(t.tolSplitHz);
            else if (key == "builtin")    ok = p.boolean(t.builtin);
            else if (key == "points")     { ok = p.points(t.points); gotPoints = ok; }
            else return false;  // unknown key: not one of ours
            if (!ok) return false;
        } while (p.eat(','));
        if (!p.eat('}')) return false;
    }
    p.ws();
    if (p.i != json.size() || !gotId || !gotPoints) return false;
    out = std::move(t);
    return true;
}

}  // namespace lyra::dsp::coach
