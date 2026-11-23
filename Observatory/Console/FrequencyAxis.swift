import CoreGraphics

/// Linear frequency-to-x mapping shared by the spectrum, band plan, spots, scale and waterfall.
struct FrequencyAxis: Sendable, Equatable {
    let lowHz: Int64
    let highHz: Int64
    let width: CGFloat

    nonisolated init(lowHz: Int64, highHz: Int64, width: CGFloat) {
        self.lowHz = lowHz
        self.highHz = highHz
        self.width = width
    }

    nonisolated private var spanHz: Double { Double(max(highHz - lowHz, 1)) }

    /// Horizontal position of `hz`; values outside the span map outside `0...width`.
    nonisolated func x(for hz: Int64) -> CGFloat {
        CGFloat(Double(hz - lowHz) / spanHz) * width
    }

    /// Nearest frequency at horizontal position `x`.
    nonisolated func hz(at x: CGFloat) -> Int64 {
        guard width > 0 else { return lowHz }
        return lowHz + Int64((Double(x / width) * spanHz).rounded())
    }

    /// True when `hz` lies inside the span (inclusive).
    nonisolated func contains(_ hz: Int64) -> Bool { hz >= lowHz && hz <= highHz }

    /// Multiples of `stepHz` from the first one at or above `lowHz` up to `highHz`.
    nonisolated func ticks(every stepHz: Int64) -> [(hz: Int64, x: CGFloat)] {
        guard stepHz > 0 else { return [] }
        var hz = ((lowHz + stepHz - 1) / stepHz) * stepHz
        var out: [(hz: Int64, x: CGFloat)] = []
        while hz <= highHz {
            out.append((hz, x(for: hz)))
            hz += stepHz
        }
        return out
    }
}
