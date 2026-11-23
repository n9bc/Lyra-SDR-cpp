import Foundation

/// What the MOX button and the transmit meters may show for a given transmit state.
///
/// Safety-critical: nothing indicates transmission (fill, glow, live meters) until the radio
/// reports `.onAir`. Every other state, including `.requested`, stays unlit.
struct MOXPresentation: Equatable, Sendable {
    nonisolated let isLit: Bool
    nonisolated let label: String
    nonisolated let caption: String?
    nonisolated let metersLive: Bool
    nonisolated let headerDetail: String

    nonisolated init(state: TransmitState) {
        label = "MOX"
        switch state {
        case .idle:
            isLit = false; caption = nil; metersLive = false; headerDetail = "Idle"
        case .requested:
            isLit = false; caption = "KEYING\u{2026}"; metersLive = false; headerDetail = "Keying\u{2026}"
        case .onAir:
            isLit = true; caption = nil; metersLive = true; headerDetail = "On air"
        case .releasing:
            isLit = false; caption = "RELEASING\u{2026}"; metersLive = false; headerDetail = "Releasing\u{2026}"
        case .blocked(let reason):
            isLit = false; caption = reason; metersLive = false; headerDetail = "Blocked"
        }
    }
}
