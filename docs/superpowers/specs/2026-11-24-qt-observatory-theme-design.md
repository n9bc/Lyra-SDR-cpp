# Qt Observatory Theme — Console View Design

**Date:** 2026-11-24
**Scope:** Port the Observatory neon design system to the Qt/QML console
view so the Windows build matches the macOS console pixel-for-pixel.

## Intent and Why

Lyra has two UI frontends: Qt/QML (Windows) and Observatory/SwiftUI
(macOS). The Observatory console has a refined neon design system
(`LyraDesignSystem.swift`) with ~60 named color tokens, spacing scales,
glow effects, and console-specific chip/slider/meter styles. The Qt side
still runs the older Python-Lyra theme — same palette family (cyan on
dark) but simpler, with no glow effects, no console-specific tokens, and
the old layout.

The goal is visual parity: a Windows user sees the same console as a
macOS user.

## Goals

- The Qt console view matches the Observatory console screenshot:
  same layout regions, same color tokens, same chip/slider/meter styling.
- A QML design-system singleton (`LyraDS`) mirrors the Swift
  `LyraDesignSystem.swift` token-for-token.
- The existing `theme.h` QSS stylesheet updates to use the new palette
  for dock titles, menus, dialogs, and other QtWidgets chrome.
- The panadapter and waterfall RHI shaders use the Observatory spectrum
  gradient ramp.

## Non-Goals

- Settings dialogs, EQ, calibration, and other non-console panels (later phase).
- The 3D audio terrain (requires a new RHI shader; separate milestone).
- Multiple VFO styles — we converge on the Observatory style for now.
- Functional changes — this is purely visual; no backend/engine changes.

## Anti-Goals

- A "close enough" theme that drifts from Observatory. The token values
  must be identical, not approximated.
- Over-abstracting a shared theme format consumed by both Swift and QML.
  Each platform owns its tokens in its native idiom.

## Constraints

- Qt 6.11, C++23, QML. No new dependencies.
- The Qt side uses `QMainWindow` + `QDockWidget` for panel docking, not
  the fixed `VStack`/`HStack` layout Observatory uses. The console view
  will be a fixed-layout QML scene inside the central dock area,
  matching Observatory's `ConsoleLayout` dimensions.
- RHI shaders (GLSL via Qt Shader Tools) replace Metal shaders; the
  visual output must match.

## Approaches Considered

### A. Token-first singleton (chosen)

Port `LyraDesignSystem.swift` to a QML singleton (`LyraDS.qml`) with
identical token names and values. Restyle each console panel against
those tokens. Update `theme.h` QSS to reference the new palette for
QtWidgets chrome.

**Pros:** Single source of truth per platform. Tokens can be audited
side-by-side. Consistent styling across all panels.
**Cons:** Two files to keep in sync (Swift and QML), but each is
<150 lines and changes rarely.

### B. Panel-by-panel visual match (rejected)

Restyle each QML panel by eyeballing the Observatory screenshot,
hardcoding colors inline.

**Rejected:** Colors drift. No auditability. Maintenance burden grows
with every panel.

### C. Shared JSON theme (rejected)

A single JSON file consumed by both Swift and QML at build time.

**Rejected:** Adds build complexity, doesn't handle platform-specific
extensions (SwiftUI gradients, QML property bindings), and the token
set is small enough that two native files are simpler.

## Console Layout (from Observatory `ConsoleLayout.swift`)

The console is five stacked regions, 8 px gap between each:

```
┌──────────────────────────────────────────────────┐
│  Top Bar (46 px)                                 │
├──────────────────────────────────────────────────┤
│  VFO Row (212 px)                                │
│  ┌─────────┐ ┌──────┐ ┌─────────┐               │
│  │ MAIN VFO│ │Center│ │ SUB VFO │               │
│  │         │ │190 px│ │         │               │
│  └─────────┘ └──────┘ └─────────┘               │
├──────────────────────────────────────────────────┤
│  Body (flexible)                                 │
│  ┌────────┐ ┌──────────────────┐ ┌────────┐     │
│  │Receiver│ │   Display Area   │ │Band/   │     │
│  │Column  │ │  (spectrum/wf/   │ │Mode    │     │
│  │300 px  │ │   terrain)       │ │Column  │     │
│  │        │ │  min 640 px      │ │300 px  │     │
│  └────────┘ └──────────────────┘ └────────┘     │
├──────────────────────────────────────────────────┤
│  Transmit Deck (122 px)                          │
├──────────────────────────────────────────────────┤
│  Status Bar (26 px)                              │
└──────────────────────────────────────────────────┘

Minimum window: 1280 x 800
```

## Design Tokens to Port

From `LyraDesignSystem.swift` → `LyraDS.qml`:

### Palette (all values as hex strings)
- **Accent colors:** electricBlue `#2E6BFF`, cyan `#00E5FF`, purple
  `#8B5CF6`, magenta `#FF2BD6`, pink `#FF5C8A`, yellow `#FFD23F`,
  green `#2BFF88`
- **Surfaces:** void `#05060B`, surface `#0B0D17`, surfaceElevated `#131628`
- **Text:** textPrimary `#EAF2FF`, textMuted `#8A93B2`, textDim `#4F5675`
- **Console-specific:** ~30 tokens for VFO borders/fills, chip states,
  meter tracks, bar fills, segment colors (see source file for full list)
- **Spectrum gradient:** 5-stop ramp (electricBlue → cyan → purple →
  magenta → yellow)

### Spacing
- xs 4, sm 8, md 12, lg 16, xl 24

### Radius
- sm 6, md 10, lg 16

### Chip button styles
Seven states from `ConsoleStyles.swift`: plain, on, sub, armed, warn,
hot, dim — each with distinct fill, border, and text colors derived
from palette tokens.

## Component Mapping

| Observatory (SwiftUI)        | Qt (QML) target              | Notes |
|------------------------------|------------------------------|-------|
| `ConsoleView`                | New `ConsoleView.qml`        | Fixed-layout central widget |
| `TopBarView`                 | New `TopBarView.qml`         | Connection status, toolbar |
| `VFOPanelView`               | Restyle `VfoBox.qml`         | Use Observatory VFO design |
| `VFOCenterColumn`            | New `VfoCenterColumn.qml`    | MAIN/SUB switch, A↔B, split |
| `ReceiverColumnView`         | Restyle panels (Audio, AGC, etc.) | Left column sections |
| `BandModeColumnView`         | Restyle panels (Band, Mode, Filter) | Right column sections |
| `DisplayAreaView`            | Restyle `PanadapterPanel.qml` | Spectrum + waterfall stack |
| `TransmitDeckView`           | Restyle `TxPanel.qml`        | TX controls strip |
| `StatusBarView`              | New `StatusBarView.qml`      | Bottom status strip |
| `ConsoleChipButtonStyle`     | New `ConsoleChip.qml`        | 7-state chip component |
| `ConsoleSectionHeader`       | New `ConsoleSectionHeader.qml` | Section title + detail |
| `ConsoleThrottledSliderRow`  | New `ConsoleSliderRow.qml`   | Label + slider + readout |
| `SegmentMeterView`           | New `SegmentMeter.qml`       | S-meter segments |
| `NeonSpectrumRenderer`       | Update panadapter RHI shader | Match gradient ramp |
| `WaterfallRenderer`          | Update waterfall RHI shader  | Match color map |

## What's Left to the Builder

- Exact QML layout syntax and anchoring for the five-region console.
- RHI shader GLSL that reproduces the Metal spectrum/waterfall visuals.
- How the fixed console layout coexists with the existing `QDockWidget`
  framework (likely: the console is the central widget, docks are for
  secondary panels like Settings, EQ, CW Decoder).
- Font selection: Observatory uses SF Mono (system monospaced) for
  frequencies; Qt will use the platform monospaced font or bundle one.
- Neon glow effects: Observatory uses layered `shadow()` modifiers;
  QML equivalent is layered `DropShadow` or shader effects.
