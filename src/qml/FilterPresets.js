.pragma library
// Per-mode RX/TX filter bandwidth presets (Hz), from old Lyra — shared by
// the Filters panel and the VFO's Filter picker so both offer the same list.
//
// A bandwidth that isn't a preset (dragged passband edge, CAT, a profile)
// is shown as an extra entry at the top of the list, labelled with the
// caller's `customSuffix`, and selected.  Picking a real preset drops it.

var bwSSB = [1500, 1800, 2100, 2400, 2700, 3000, 3600, 4000, 6000, 8000, 10000]
var bwCW  = [50, 100, 150, 250, 400, 500, 750, 1000]
var bwDSB = [3000, 4000, 5000, 6000, 8000, 10000]
var bwAM  = [3000, 4000, 6000, 8000, 10000, 12000, 16000, 20000]
// FM RX presets are the FM CHANNEL widths the IF must pass, not SSB
// widths: narrow FM (±2.5 kHz dev) ≈ 12 k, wide FM (±5 kHz dev) ≈ 16 k
// (Carson: 2·(dev + 3 kHz audio)).  8/10 cover data/very-narrow.
var bwFM  = [8000, 10000, 12000, 16000]
var bwDIG = [1500, 2400, 3000, 3600, 4000, 6000]

function presetsFor(mode) {
    if (mode === "LSB" || mode === "USB") return bwSSB
    if (mode === "CWL" || mode === "CWU") return bwCW
    if (mode === "DSB") return bwDSB
    if (mode === "AM" || mode === "SAM") return bwAM
    if (mode === "FM")  return bwFM
    if (mode === "DIGL" || mode === "DIGU") return bwDIG
    return bwSSB
}

function fmtBw(hz) {
    return hz >= 1000 ? (hz / 1000).toFixed(hz % 1000 ? 1 : 0) + " k"
                      : hz + " Hz"
}

function isPreset(mode, bw) {
    return presetsFor(mode).indexOf(bw) >= 0
}

function model(mode, bw, customSuffix) {
    var labels = presetsFor(mode).map(fmtBw)
    if (isPreset(mode, bw)) return labels
    return [fmtBw(bw) + customSuffix].concat(labels)
}

function currentIndex(mode, bw) {
    var i = presetsFor(mode).indexOf(bw)
    return i < 0 ? 0 : i                     // 0 = the custom entry
}

// Map a picked index back to Hz.  `bw` is the bandwidth the model was built
// from, so the offset for the optional leading custom entry is consistent.
function valueAt(mode, bw, idx) {
    var p = presetsFor(mode)
    if (isPreset(mode, bw)) return p[idx]
    return idx === 0 ? bw : p[idx - 1]
}
