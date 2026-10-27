// Lyra — TX monitor routing decision (eSSB practice loop).
//
// The post-rack TX monitor (WdspEngine::txMonitorTapCb -> monitorRing_) can
// reach three destinations from dispatchAudioFrame: the local output
// (Route 1), the VAC stream-2 feed (Route 2) and the TCI RX stream (Route 3).
// Historically all three shared one flag, monEnabled && txMuted.  The
// practice loop plays an unkeyed clip through the rack and must be heard on
// the headphones (local) even with MON off, while VAC and TCI keep carrying
// RX exactly as before — practice audio never goes remote.
//
//   fillTap : the TX thread writes the monitor ring.
//   local   : Route 1 plays the monitor in place of RX audio.
//   remote  : Routes 2 and 3 carry the monitor (MOX monitor only).
//
// Pure and constexpr: safe to call from the audio and cm TX threads.

#pragma once

namespace lyra::dsp {

struct MonitorRoute {
    bool fillTap;
    bool local;
    bool remote;
};

constexpr MonitorRoute routeMonitor(bool monEnabled, bool txMuted, bool practice)
{
    return MonitorRoute{
        monEnabled || practice,
        (monEnabled && txMuted) || practice,
        monEnabled && txMuted,
    };
}

} // namespace lyra::dsp
