# Qt Observatory Theme — Console View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Observatory neon design system to the Qt/QML console view so the Windows build matches the macOS console visually.

**Architecture:** A new QML singleton (`LyraDS`) holds every Observatory color token, spacing value, and radius. New console-specific QML components (chip button, section header, throttled slider row, segment meter) provide the console's UI vocabulary. The existing dock panels are restyled against these tokens. The `theme.h` QSS stylesheet updates to the Observatory palette for all QtWidgets chrome.

**Tech Stack:** Qt 6.11, C++23, QML, GLSL (Qt Shader Tools → qsb), CMake

**Spec:** `docs/superpowers/specs/2026-11-24-qt-observatory-theme-design.md`

## Global Constraints

- Qt 6.11+, C++23. No new dependencies.
- All color values must be byte-identical to `Observatory/Theme/LyraDesignSystem.swift`.
- QML files register in the `Lyra` module via `qt_add_qml_module` in `CMakeLists.txt`.
- Shaders compile via `qt_add_shaders` to `.qsb` (SPIR-V/MSL/HLSL/GLSL).
- New branch `qt-observatory-theme` off `macos-port`.

## Review Focus

1. **Color token drift** — a hex value in QML that doesn't match the Swift source file silently diverges the two platforms. Every token value must be mechanically verified against `LyraDesignSystem.swift`.
2. **Opacity-on-hex ambiguity** — Observatory uses `Color.opacity(0.08)` on named colors; QML uses `Qt.rgba()` with alpha or `"#AARRGGBB"`. Confirm the alpha math produces the same visual result.
3. **Font metrics on Windows** — Observatory uses SF Mono (macOS system); Qt uses Share Tech Mono (bundled) or platform monospaced. VFO digit widths may differ; verify digit columns don't reflow.
4. **QSS vs QML token collision** — `theme.h` QSS applies app-wide to QtWidgets; QML panels have their own styling. A QSS rule that bleeds into a QQuickWidget's native controls would fight the QML tokens.
5. **Glow shader performance** — the `glow.frag` 9×9 gaussian is already in the shader pipeline; changing threshold/strength values to match Observatory's neon look could change GPU load on low-end Windows hardware.

---

### Task 1: Branch and Design Token Singleton

**Files:**
- Create: `src/qml/LyraDS.qml`
- Modify: `CMakeLists.txt:648` (add to QML_FILES)

**Interfaces:**
- Consumes: nothing
- Produces: `LyraDS.palette.*`, `LyraDS.space.*`, `LyraDS.radius.*` — QML singleton properties accessible from any QML file in the `Lyra` module. Every property is `readonly property color` or `readonly property real`.

- [ ] **Step 1: Create branch `qt-observatory-theme` off `macos-port`**

```bash
git checkout macos-port
git checkout -b qt-observatory-theme
```

- [ ] **Step 2: Create `src/qml/LyraDS.qml` with all Observatory palette tokens**

Singleton pragma at top. Three sub-objects via `QtObject`: `palette`, `space`, `radius`.

Palette properties — transcribe every `static let` from `LyraDesignSystem.swift` `Palette` enum as `readonly property color`. For opacity-based colors like `border = Color.white.opacity(0.08)`, use `Qt.rgba(1, 1, 1, 0.08)`.

Spacing: `xs: 4`, `sm: 8`, `md: 12`, `lg: 16`, `xl: 24`.
Radius: `sm: 6`, `md: 10`, `lg: 16`.

Include `spectrumStops` as a `readonly property var` — an array of `{position, r, g, b}` objects matching the 5-stop ramp.

- [ ] **Step 3: Register singleton in CMakeLists.txt**

Add `src/qml/LyraDS.qml` to the `QML_FILES` list in the `qt_add_qml_module(lyra` block.

- [ ] **Step 4: Verify — build compiles with the new file**

Run: `cmake --build build --target lyra 2>&1 | tail -20`
Expected: clean build, no QML errors.

- [ ] **Step 5: Commit**

```bash
git add src/qml/LyraDS.qml CMakeLists.txt
git commit -m "feat(theme): add LyraDS QML singleton with Observatory design tokens"
```

---

### Task 2: Console Chip Button Component

**Files:**
- Create: `src/qml/ConsoleChip.qml`
- Create: `src/qml/ConsoleSectionHeader.qml`
- Modify: `CMakeLists.txt:648` (add to QML_FILES)

**Interfaces:**
- Consumes: `LyraDS.palette.*` (Task 1)
- Produces: `ConsoleChip { title, help, kind, height, fullWidth, onClicked }` — a styled button with 7 visual states. `ConsoleSectionHeader { title, detail }` — a section label row.

- [ ] **Step 1: Create `src/qml/ConsoleChip.qml`**

A `Button`-based component. Properties: `title` (string), `help` (string, sets `accessibilityLabel` and `ToolTip`), `kind` (string enum: `"plain"`, `"on"`, `"sub"`, `"armed"`, `"warn"`, `"hot"`, `"dim"`), `height` (real, default 26), `fullWidth` (bool, default false).

Internal logic maps `kind` to fill/border/text colors using the exact Observatory `ConsoleChipButtonStyle` mapping from `ConsoleStyles.swift`:
- `plain`: fill = `chipFill`, border = `chipBorder`, text = `chipText`
- `on`: fill = `cyan @ 0.10`, border = `cyan`, text = `cyan`, shadow = `cyan @ 0.22` radius 6
- `sub`: fill = `purple @ 0.12`, border = `purple`, text = `chipSubText`
- `armed`: fill = `green @ 0.08`, border = `green`, text = `green`
- `warn`: fill = `yellow @ 0.08`, border = `yellow`, text = `yellow`
- `hot`: fill = `pink @ 0.10`, border = `pink`, text = `pink`
- `dim`: fill = `chipDimFill`, border = `chipBorder`, text = `chipDimText`

Body: `RoundedRectangle` corner radius 7, 12pt medium font, 9px horizontal padding. Disabled state: `chipDimText`/`chipDimFill`/`chipBorder`, 0.45 opacity. Pressed: 0.7 opacity.

- [ ] **Step 2: Create `src/qml/ConsoleSectionHeader.qml`**

A `Row` with two `Text` items: `title` (left, `textMuted`, 11pt semibold, uppercased) and `detail` (right-aligned, `cyan`, 11pt medium). Background: none. Full width of parent.

- [ ] **Step 3: Register both in CMakeLists.txt**

- [ ] **Step 4: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add src/qml/ConsoleChip.qml src/qml/ConsoleSectionHeader.qml CMakeLists.txt
git commit -m "feat(theme): add ConsoleChip and ConsoleSectionHeader QML components"
```

---

### Task 3: Console Slider Row and Segment Meter

**Files:**
- Create: `src/qml/ConsoleSliderRow.qml`
- Create: `src/qml/SegmentMeter.qml`
- Modify: `CMakeLists.txt:648` (add to QML_FILES)

**Interfaces:**
- Consumes: `LyraDS.palette.*` (Task 1)
- Produces: `ConsoleSliderRow { label, help, value, from, to, stepSize, readout, tint, dimmed, onMoved }` — a row with label, themed slider, and readout text. `SegmentMeter { value, peak, segments }` — a horizontal segment bar for S-meter display.

- [ ] **Step 1: Create `src/qml/ConsoleSliderRow.qml`**

A `RowLayout`: `Text` label (11pt, `textMuted`, fixed 60px width), `Slider` (groove: `meterTrack`, handle: `tint` color, track fill up to handle in `tint`), `Text` readout (11pt monospaced, `textPrimary`, right-aligned, 50px width). The `tint` property defaults to `LyraDS.palette.cyan`. When `dimmed` is true, all elements draw at 0.45 opacity.

- [ ] **Step 2: Create `src/qml/SegmentMeter.qml`**

A row of rectangles. Properties: `value` (0-1 fraction), `peak` (0-1 fraction, hold line), `segments` (int, default 20). Each segment: 3px wide, 1px gap, `segmentOff` when below value, `cyan` when at or below value, segments above 75% fill `yellow`, above 90% fill `pink`. Peak hold: a single segment at the peak position in `textPrimary`. Scale labels rendered by the parent (not in this component).

- [ ] **Step 3: Register both in CMakeLists.txt**

- [ ] **Step 4: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/qml/ConsoleSliderRow.qml src/qml/SegmentMeter.qml CMakeLists.txt
git commit -m "feat(theme): add ConsoleSliderRow and SegmentMeter QML components"
```

---

### Task 4: Restyle Core Controls (LyraButton, LyraSlider)

**Files:**
- Modify: `src/qml/LyraButton.qml`
- Modify: `src/qml/LyraSlider.qml`
- Modify: `src/qml/LyraComboBox.qml`
- Modify: `src/qml/LyraSpinBox.qml`

**Interfaces:**
- Consumes: `LyraDS.palette.*` (Task 1)
- Produces: same public API as before; only visual output changes.

- [ ] **Step 1: Restyle `LyraButton.qml`**

Replace hardcoded colors with `LyraDS.palette` tokens:
- `background.color`: unchecked = `surfaceElevated`, checked = `cyan @ 0.10`, hovered = surface with `border` highlighted, pressed = `surface`
- `border.color`: unchecked = `panelBorder` (white @ 0.07), checked = `cyan`, hovered = `cyan`
- `contentItem.color`: unchecked = `chipText`, checked = `cyan`

- [ ] **Step 2: Restyle `LyraSlider.qml`**

Replace hardcoded colors:
- Groove: `meterTrack` (`#171A2E`), no border
- Track fill: `cyan`
- Handle: `cyan` (normal), brighter on hover, dimmer on press
- Tick marks and labels: `textDim`

- [ ] **Step 3: Restyle `LyraComboBox.qml` and `LyraSpinBox.qml`**

Same pattern: replace hardcoded hex values with `LyraDS.palette` references. Background = `surfaceElevated`, border = `panelBorder`, text = `textPrimary`, focus border = `cyan`.

- [ ] **Step 4: Verify — build compiles, no QML binding errors**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/qml/LyraButton.qml src/qml/LyraSlider.qml src/qml/LyraComboBox.qml src/qml/LyraSpinBox.qml
git commit -m "feat(theme): restyle core QML controls to Observatory palette"
```

---

### Task 5: Restyle VFO Panel

**Files:**
- Create: `src/qml/VfoStyleObservatory.qml`
- Modify: `src/qml/VfoStyles.js` (register new style)
- Modify: `src/qml/VfoBox.qml` (default to Observatory style)
- Modify: `CMakeLists.txt:648` (add new QML file)

**Interfaces:**
- Consumes: `LyraDS.palette.*` (Task 1), VFO style contract from `VfoBox.qml` (existing)
- Produces: `VfoStyleObservatory` — a VFO style implementing the existing style contract with Observatory's visual design.

- [ ] **Step 1: Create `src/qml/VfoStyleObservatory.qml`**

Implements the VFO style contract (see `VfoBox.qml` lines 11-17): provides `naturalWidth`, `naturalHeight`, `tuneRect`, `digitRects`, `stepModeRect`, `txPipRect`, and `theme` object.

Visual design from `VFOPanelView.swift`:
- Background: linear gradient `vfoTop` → `vfoBottom`
- Border: `vfoBorder` (1px), when focused: `vfoBorderHighlight` with outer glow `vfoGlowHighlight`
- Frequency digits: `freqGlow` color, monospaced (Share Tech Mono bundled font), glow shadow on active digit
- S-meter: `SegmentMeter` (Task 3) embedded in the VFO panel
- Header chips row: VFO letter, TX/RX role tag, step, mode (using `ConsoleChip` from Task 2)
- TX tag: filled `txFill` background, `txText` label, only visible when transmitting

Theme object values:
```
{ label: LyraDS.palette.textMuted, field: LyraDS.palette.vfoBottom,
  fieldBorder: LyraDS.palette.vfoBorder, text: LyraDS.palette.freqGlow,
  accent: LyraDS.palette.cyan, pipIdle: LyraDS.palette.moxIdleFill,
  pipIdleBorder: LyraDS.palette.pink, pipIdleText: LyraDS.palette.moxHint,
  compact: false }
```

- [ ] **Step 2: Register in `VfoStyles.js`**

Add `"Observatory"` entry pointing to `VfoStyleObservatory`.

- [ ] **Step 3: Set Observatory as default in `VfoBox.qml`**

Change the fallback style from the current default to `"Observatory"` when `Prefs.vfoStyle` is unset or set to `"Observatory"`.

- [ ] **Step 4: Register `VfoStyleObservatory.qml` in CMakeLists.txt**

- [ ] **Step 5: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 6: Commit**

```bash
git add src/qml/VfoStyleObservatory.qml src/qml/VfoStyles.js src/qml/VfoBox.qml CMakeLists.txt
git commit -m "feat(theme): add Observatory VFO style with neon design tokens"
```

---

### Task 6: Restyle Receiver Column Panels

**Files:**
- Modify: `src/qml/AudioPanel.qml`

**Interfaces:**
- Consumes: `LyraDS.palette.*` (Task 1), `ConsoleChip` (Task 2), `ConsoleSliderRow` (Task 3), `ConsoleSectionHeader` (Task 2)
- Produces: same public API; visual output matches Observatory's `ReceiverColumnView`.

- [ ] **Step 1: Restyle `AudioPanel.qml` backgrounds and borders**

Replace:
- `Prefs.panelBgColor` → `LyraDS.palette.surface`
- `"#2a4a5a"` border → `LyraDS.palette.panelBorder`
- Inline accent colors (`cAccent`, `cText`, `cMuted`, `cDim`, `cOn`) → corresponding `LyraDS.palette` tokens

The panel contains Front End, Audio, AGC, and Noise/DSP sections matching Observatory's `ReceiverColumnView` sections. Each section gets a `ConsoleSectionHeader` with the Observatory title and detail text.

- [ ] **Step 2: Replace inline button styling with ConsoleChip**

Where the panel uses `LyraButton` for toggle-style controls (NB, BIN, NR, ANF, etc.), replace with `ConsoleChip` using the appropriate `kind`:
- Off state → `"plain"`
- On/active state → `"on"` (cyan glow)
- Engaged DSP → `"on"`

- [ ] **Step 3: Replace inline slider styling with ConsoleSliderRow**

Where the panel uses `LyraSlider` with adjacent label/readout, replace with `ConsoleSliderRow` to get the unified layout and Observatory styling.

- [ ] **Step 4: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/qml/AudioPanel.qml
git commit -m "feat(theme): restyle AudioPanel to Observatory neon design"
```

---

### Task 7: Restyle Band/Mode Column Panels

**Files:**
- Modify: `src/qml/BandPanel.qml`
- Modify: `src/qml/ModeFilterPanel.qml`

**Interfaces:**
- Consumes: `LyraDS.palette.*` (Task 1), `ConsoleChip` (Task 2), `ConsoleSectionHeader` (Task 2)
- Produces: same public API; visual output matches Observatory's `BandModeColumnView`.

- [ ] **Step 1: Restyle `BandPanel.qml`**

Replace:
- `Prefs.panelBgColor` → `LyraDS.palette.surface`
- `"#2a4a5a"` border → `LyraDS.palette.panelBorder`
- Band chips: replace inline button styling with `ConsoleChip`. Active band → `kind: "on"` (cyan). Active SUB band → `kind: "sub"` (purple). Inactive → `kind: "plain"`.
- Section headers (AMATEUR, BC, GEN, XVTR) → `ConsoleSectionHeader`
- Tab row (Ham, BC, Gen, Time, Xvtr, Mem) → row of `ConsoleChip` with `height: 22`, `fullWidth: true`

- [ ] **Step 2: Restyle `ModeFilterPanel.qml`**

Replace colors with tokens:
- Mode chips (LSB, USB, CWL, etc.): `ConsoleChip`, active mode → `kind: "on"`, inactive → `kind: "plain"`
- Filter bandwidth chips: same pattern
- BW lock toggle: `ConsoleChip` with `kind: "hot"` when locked (pink accent, matching Observatory)
- Section headers → `ConsoleSectionHeader`

- [ ] **Step 3: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add src/qml/BandPanel.qml src/qml/ModeFilterPanel.qml
git commit -m "feat(theme): restyle Band and Mode/Filter panels to Observatory design"
```

---

### Task 8: Update theme.h QSS Stylesheet

**Files:**
- Modify: `src/theme.h`

**Interfaces:**
- Consumes: `LyraDS` palette values (Task 1) — the QSS uses the same hex values, just in `rgb()` syntax
- Produces: updated app-wide QtWidgets stylesheet matching Observatory palette

- [ ] **Step 1: Update color tokens in `lyraStyleSheet()`**

Replace the old Python-Lyra token values with Observatory equivalents:

| Old token | Old value | New value (from LyraDS) |
|---|---|---|
| BG_APP | `rgb(10,13,18)` | `rgb(5,6,11)` (void `#05060B`) |
| BG_PANEL | `rgb(17,22,32)` | `rgb(11,13,23)` (surface `#0B0D17`) |
| BG_RECESS | `rgb(16,20,28)` | `rgb(11,13,23)` (surface) |
| BG_CTRL | `rgb(22,28,40)` | `rgb(19,22,40)` (surfaceElevated `#131628`) |
| ACCENT | `rgb(0,229,255)` | `rgb(0,229,255)` (cyan — same) |
| ACCENT_DIM | `rgb(0,168,200)` | `rgb(46,107,255)` (electricBlue `#2E6BFF`) |
| ACCENT2 | `rgb(57,255,20)` | `rgb(43,255,136)` (green `#2BFF88`) |
| TEXT_PRIMARY | `rgb(205,217,229)` | `rgb(234,242,255)` (textPrimary `#EAF2FF`) |
| TEXT_MUTED | `rgb(138,154,172)` | `rgb(138,147,178)` (textMuted `#8A93B2`) |
| TEXT_FAINT | `rgb(90,112,128)` | `rgb(79,86,117)` (textDim `#4F5675`) |
| BORDER | `rgb(30,42,58)` | `rgba(255,255,255,20)` (border = white @ 0.08) |

Update every QSS rule that uses these values. The comment block at the top of the file documents the token mapping — update it to reference Observatory.

- [ ] **Step 2: Update dock title bar styling**

The `QDockWidget::title` gradient should use `surface` → `surfaceElevated` → `surface`. Title text color stays `cyan`. The bottom border uses `cyan @ 0.3` (matching Observatory's panel accent line).

- [ ] **Step 3: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add src/theme.h
git commit -m "feat(theme): update QSS stylesheet to Observatory palette"
```

---

### Task 9: Update Spectrum Gradient in Panadapter

**Files:**
- Modify: `src/panadapter.cpp` (or the QML that feeds gradient uniforms to the shader)

**Interfaces:**
- Consumes: `LyraDS.palette.spectrumStops` (Task 1)
- Produces: panadapter spectrum trace and fill use the Observatory 5-stop color ramp

- [ ] **Step 1: Locate where the spectrum gradient is defined on the Qt side**

Search `src/panadapter.cpp` and `src/qml/PanadapterPanel.qml` for gradient color definitions. The panadapter likely has a gradient or color ramp used for the spectrum trace fill.

- [ ] **Step 2: Replace the gradient with Observatory's 5-stop ramp**

The Observatory ramp (`LyraDesignSystem.swift` lines 74-80):
```
position 0.0  → #2E6BFF (electricBlue)
position 0.3  → #00E5FF (cyan)
position 0.55 → #8B5CF6 (purple)
position 0.8  → #FF2BD6 (magenta)
position 1.0  → #FFD23F (yellow)
```

Apply these stops wherever the Qt panadapter defines its trace gradient — whether as QML `Gradient` stops, shader uniforms, or C++ color arrays passed to the renderer.

- [ ] **Step 3: Update `PanadapterPanel.qml` background**

Set the panadapter glass background to `LyraDS.palette.void` with the existing glow shader. Update the grid line color to `LyraDS.palette.textDim`.

- [ ] **Step 4: Verify — build compiles**

Run: `cmake --build build --target lyra 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/panadapter.cpp src/qml/PanadapterPanel.qml
git commit -m "feat(theme): apply Observatory spectrum gradient to panadapter"
```
