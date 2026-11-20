# Slice 3 visual review (Carbon, pass 2)

Carbon returned this review as its reply text without writing the file, so the orchestrator saved it here. Screenshots are in `scratchpad/slice3/`. The demo captures render the tray at 820 pt and settings at 460 pt, while production is 248–298 pt (max 360). Every fix must be judged at **production height**.

## Status of the 30 Slice 2 items
- **Verified fixed (21):** #1–7, 9, 11–13, 16, 17, 19–26, 28, 30.
- **Regressed or incomplete (9):**
  - #8 and #10: dropzone caption contrast.
  - #14: archive selector missing from the control bar, plus Settings header leaks.
  - #15: nested glass in the toast, flat pills under Reduce Transparency, and the Lossless segment contrast.
  - #18: badge contrast.
  - #27: settings toggles and overflow.
  - #29: disk-banner buttons.

## P0: ship blockers
1. **The undo toast prints `[Undo ⌘Z]` followed by an `Undo` button** (every tray capture).
   - Cause: `JobStore.adopt` (JobStore.swift:417) and `Demo.makeFixture` (Demo.swift:122) put `"  [Undo ⌘Z]"` into the message, and `UndoToast` also appends `Button("Undo")`.
   - Fix: the message is `"Replaced \(name) (original in Trash)"`, and the button label is `Undo` plus `Keycap("⌘Z")`.
   - Under Reduce Motion, use an `.opacity` transition (UndoToast.swift:41). Use a tinted, non-nested surface instead of `.glassEffect` inside the glass tray.
2. **Dropzone captions are illegible.**
   - The aimed caption is blue on blue: `#3C82F6` on `#3D4A6C` = 2.39:1.
   - The dimmed half is double-dimmed: 1.80–1.86:1.
   - The done-pill subline is 3.15:1.
   - Fix in `DropzoneView.half(_:)`:
     - Aimed half: symbol and caption in `Color.primary.opacity(0.90)`, or `#BFDBFE` dark / `#1E40AF` light.
     - Dimmed half: drop the extra `.opacity(0.5)`; use title `primary.opacity(0.72)` and caption `primary.opacity(0.62)`.
     - Done subline (`DropzoneView.result`): `primary.opacity(0.72)`.
   - Target: every text ≥ 4.5:1.
3. **The Settings deck overflows the production tray, and the toggles are misaligned.**
   - Column 2 has 7 rows and is 282.5 pt tall, but only 184–234 pt is available below the control bar (148–198 pt while the disk banner shows). ux.md §2.3 says Settings never scrolls on a 13" Air.
   - The 4 switches pack left, mid-column.
   - Fix:
     - Add a `toggleRow(_:isOn:)` helper: `HStack { Text(title).foregroundStyle(.secondary); Spacer(); Toggle("", isOn:).labelsHidden() }`.
     - Rebalance to **≤ 5 compact rows of 24–26 pt per column**, so every column fits within **184 pt**. For example, move Workers and Preserve dates to column 3.
     - Capture demo screenshots at the real `PanelGeometry.trayFrame` height, not 820 or 460 pt.
4. **Menu-bar glyph problems.**
   - The progress arc fuses into the right bracket.
   - The live `StatusGlyph.image` (Tokens.swift:315) grows its canvas from 16 to 20 pt while jobs run, so the menu bar jitters by 4 pt.
   - Two divergent glyph renderers exist: `make-icon.swift` `renderGlyph` and `StatusGlyph`.
   - Fix:
     - Use one shared renderer with a **fixed 18×18 pt canvas** in every state.
     - Jaws pinch **inward** (⟩ • ⟨): tips at x = 0.24 / 0.76, waist control at x = 0.38 / 0.62.
     - Keep at least 2 pt of air between the jaws and the progress ring (the inner mark scales to 0.62× inside a 7.5 pt-radius ring).
5. **The app icon is full-bleed (0 px margin) and breaks the macOS icon grid.**
   - Parentheses bow outward, and a white centre stripe splits each jaw into a hollow double track.
   - Fix: see the icon spec below.

## P1
6. **Status badges fail 4.5:1 in both modes.**
   - Measured: Stopped 1.88–2.02, Waiting 2.5–2.6, the 40% badge 2.7–3.7, Optimal 3.16, Failed about 4.1.
   - Fix:
     - Stop dimming whole queued or cancelled cards with `.opacity(cardOpacity)`; dim only the thumbnail.
     - Tokens:
       - `cobaltText`: `#60A5FA` dark / `#1D4ED8` light.
       - `coralText`: `#FCA5A5` dark / `#B91C1C` light.
       - neutral badge text: `primary.opacity(0.78)`.
       - badge fills: 0.12–0.14.
7. **Under Reduce Transparency, control-bar pills are `#1E1E1E` on `#1E1E1E`** (1.00:1).
   - Fix: when flat, fill with `white.opacity(hover ? 0.14 : 0.09)` in dark, `black.opacity(hover ? 0.09 : 0.055)` in light, plus a 1 pt `separatorColor` border.
   - Locations: `SoftPillBackground` (ControlBar.swift:204) and `AdaptiveGlassSurface.pillChrome` (Glass.swift:56).
8. **Low-contrast buttons.**
   - The unselected Lossless segment is 3.2–3.3:1. Use `primary.opacity(0.75)`.
   - Disk-banner Resume is 2.9:1 in light. Use white on solid `#DC2626`, or `#991B1B` light / `#FECACA` dark text on a lighter tint.
9. **Settings mode leaks queue chrome.**
   - Clear Done, the disk banner and the undo toast stay visible. The Done pill and the gear button both close Settings. "Settings" is misaligned.
   - Fix: hide those three while `settingsOpen`, keep one close control, and set "Settings" in 14 pt semibold aligned with the deck.
10. **The batch header reads as heading all 7 cards.**
    - Its savings lack a "−", and it sits over the empty action slot.
    - Fix: prefix "−", align it with the badge column (`.padding(.trailing, 134)`), and group batched rows visually (a platter, a 2 pt accent rail, or 14 pt spacing before unbatched rows).
11. **Failed and cancelled cards hide Retry / Choose Folder… until hover.**
    - Fix: keep the primary recovery action visible at rest on failed cards, and expose it as an accessibility action.
12. **The demo replaced card says "Replaced .pdf → .pdf".**
    - Production only sets `replacedNote` when the extension changes.
    - Fix: clear it, or demo a real `.png → .heic` replace.
13. **Archive format is missing from the control bar (U2).**
    - Fold it into the Format menu as `Section("Folders & Archives")`: `Smallest (.tar.xz)` / `Opens everywhere (.zip)`.
    - The pill label reflects a non-default zip.
    - Keep the toolbar at 4 pills.

## P2
14. **`DoneDragWell` overlaps 2 pt of the chevron button.** Use `pill.width - 38` (DropHostingView.swift:202).
15. **The intake-well dashed border is too loud.**
    - Use `primary.opacity(hover ? 0.42 : 0.22)` at 1 pt, and a 2 pt cobalt border while a drag is targeting.
    - Show `⌘V` as a `Keycap`.
16. **Increase Contrast doesn't reach the selected or failed borders.** Use `max(base, 1.5)` when contrast is increased.
17. **Demo fixtures must match engine behaviour.**
    - Pink HEIC: `HEIC · Smart · q80`, not "sample".
    - `.dmg` → Already optimal. The failed card becomes a write-permission failure: `Protected.pdf` → "No write permission · Choose Folder…".
    - Ship real tiny demo media, generated into a temp dir at demo launch only, so video and PDF thumbnails render.
18. **Missing captures for the next verification**, at real height (298 pt, plus 248 pt for a 13" Air):
    - the empty tray;
    - the dropzone puck;
    - the compressing state;
    - the tray drag-hover / aim chip;
    - the queue scroll feather.

## Icon spec
The orchestrator added the exact geometry here, consistent with Carbon's P0 #5.
- **Grid:** 1024×1024 canvas. The squircle body is 824×824, centred (100 px inset), with a continuous-corner radius of about 185 px (superellipse). The drop shadow under the body is offset (0, −12 px), blur 28 px, black at 28% alpha. Nothing is drawn outside the body except the shadow.
- **Background:** a vertical gradient on the body, deep cobalt `#1E3A8A` at the bottom to `#3B82F6` at the top. A soft radial light sits at the top-centre: white at 18% fading to 0 at 60% radius.
- **Foreground (glass layer):** two **inward-pinching caliper jaws** (⟩ ◆ ⟨), one mirrored on each side.
  - Each jaw is a solid rounded chevron, stroke-free and filled. The outer tip is at x = 0.30 and the inner waist at x = 0.44 for the left jaw; the right jaw mirrors at 0.70 / 0.56. Vertical span y = 0.28 to 0.72, with a thickness of about 0.075 of the width.
  - Fill is white at 92% with a subtle top-to-bottom gradient (100% to 82%).
  - A 1.5 px inner top highlight (white, 60%) simulates glass. There is no centre stripe.
- **Core:** a small faceted diamond at the centre (width about 0.14), in emerald `#10B981` to `#34D399`, with a soft emerald glow (blur 18 px, 35%). It reads as "the essential bits, squeezed".
- **Meaning:** the jaws pressing inward say compression; the bright core says nothing important is lost.
- **Small sizes (16 and 32 px):** drop the glow and highlight, thicken the jaws to about 0.10, and snap to the pixel grid.
- **Menu-bar template glyph (18×18 pt, fixed canvas):** the same ⟩ • ⟨ silhouette in black, with jaws at a 1.6 pt stroke-equivalent fill and a 2.2 pt dot. The progress ring is a separate 1.25 pt arc at radius 8 pt, kept at least 2 pt away from the jaws. The canvas never changes size.
- **Originality:** generic geometric shapes only. Do not resemble any existing app's icon.
