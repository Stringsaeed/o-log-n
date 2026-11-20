# Logn (`o-log-n`) — macOS UX, Interaction & Motion Specification

- **Target Platform**: macOS 26.0+ (Tahoe Liquid Glass native; dev baseline macOS 27.2)
- **Tech Stack**: Swift 6.4, AppKit (`NSPanel`, `NSStatusItem`, global/local event monitors) + SwiftUI (`GlassEffectContainer`, `.glassEffect`)
- **App Lifecycle**: Agent / Accessory app (`LSUIElement = YES`, `NSApp.setActivationPolicy(.accessory)`) — **no Dock icon, no standard `NSWindow`, no menu bar takeover**
- **Surfaces**: Menu Bar Anchor + Floating **Dropzone** (`NSPanel`) + Bottom **Tray** (`NSPanel`, inline Settings)

---

## 1. Product Principles & Core Flows

### 1.1 Product Principles
1. **Zero-Chrome Presence**: The app occupies `0 px` of desktop real estate at rest (except its `22 pt` menu bar glyph). Surfaces materialize at the moment and location of intent, never steal focus from the user's active document, and vanish cleanly when work is handed off.
2. **Zero-Click Intent at Drop**: Choosing between perceptual **Smart** compression and bit-exact **Lossless** compression happens *inside the drag gesture itself* via spatial drop halves (with an `⌥` keyboard toggle for muscle-memory users)—zero pre-configuration modals, zero post-drop dialogs.
3. **Non-Destructive by Construction**: Compression never produces a larger file (resolving to `Already optimal` instead) and never touches originals on drop. Replacing an original is an explicit post-compression action that stages the original in macOS Trash via `FileManager.trashItem` with single-keystroke `⌘Z` undo.
4. **Honest, Monotonic Feedback**: Parallel throughput, byte savings, and codec choices are surfaced in real time using tabular numerals without jitter. Progress never jumps backward, and errors degrade per-file inline—never halting a batch with blocking `NSAlert` sheets.

### 1.2 Core User Flows

#### Flow A — Quick Drop on Dropzone (Zero-Click Path)
1. **Drag Initiation**: User starts dragging 1 or more files in Finder, Desktop, Mail, or browser. Once pointer displacement exceeds `24 pt` from `leftMouseDown` and `NSPasteboard(name: .drag)` contains file URLs or image UTIs, the **Dropzone** springs down at Top-Center of the cursor's current screen (`228 × 60 pt` capsule).
2. **Proximity & Aim**: Moving the dragged cursor within `96 pt` of the Dropzone expands it to `280 × 76 pt`, revealing two crisp targets: **Left = Smart** (`sparkles`) and **Right = Lossless** (`checkmark.shield`). Crossing into either half fires an `.alignment` haptic and illuminates that half. (Holding `⌥` flips the active half without horizontal movement; holding `⇧` routes the drop directly into the expanded Tray.)
3. **Drop & Compress**: Releasing the mouse triggers a `.levelChange` haptic. Both halves merge via `GlassEffectContainer` into a `216 × 52 pt` progress pill showing a `24 pt` determinate ring, file count, and live monotonic savings ticker (`−14.2 MB`).
4. **Handoff**: On completion (`.generic` haptic), the pill morphs into a `236 × 56 pt` **Done Pill** for `6.0 s` (timer pauses while hovered):
   - **Drag out**: Drag the `32 × 32 pt` file thumbnail/icon directly into Slack, Mail, Safari, or another folder.
   - **Click body**: Reveals output file(s) selected in Finder (`NSWorkspace.shared.activateFileViewerSelecting`) and dismisses the pill.
   - **Click chevron (`⌄`)**: Opens the bottom Tray scrolled to this job for actions like **Replace Original**.

#### Flow B — Open Tray via Hotkey or Status Item
1. **Summon**: User presses `⌃⌥Space` (or left-clicks the menu bar icon). The **Tray** slides up from the bottom of the `NSScreen` currently containing `NSEvent.mouseLocation` (`~25.5%` screen height, `12 pt` outer margins).
2. **Inspect or Intake**: User inspects live/recent job cards, adjusts quick presets in the Top Control Bar, drops files into the Left Intake Well, presses `⌘V` to compress clipboard screenshots/files directly, or presses `⌘O` to browse.
3. **Dismiss**: Pressing `Esc`, pressing `⌃⌥Space` again, or clicking outside the Tray slides it down (`220 ms`). Active background jobs continue uninterrupted and reflect progress in the menu bar icon.

#### Flow C — Batch Drop of a Folder
1. **Drop & Enumerate**: Dropping one or more folders onto either surface recursively enumerates regular files off the main actor, skipping `.DS_Store`, `__MACOSX`, `.git/`, symlinks, and hidden dot-files by default (configurable in Settings).
2. **Surface Routing**:
   - Dropped on **Dropzone**: Runs the entire batch inside the compact batch progress pill (`Compressing 42 files · −118 MB`). Clicking anywhere on the running pill expands the Tray without interrupting workers.
   - Dropped on **Tray** (or batches `> 1` opened in Tray): Inserts a sticky **Batch Group Header Row** (`34 pt` height: `"📁 marketing-site/ · 42 files · −184 MB (−58%)"` with `Reveal Folder`, `Replace All Originals`, and `Collapse/Expand` chevron) followed by individual parallel job cards. For massive drops (`> 50` files), cards virtualize cleanly in SwiftUI `LazyVStack` while active jobs float to the top of the group until finished.
3. **Output Tree**: When output mode is `Next to original`, files write next to their respective source files (`hero-min.png`). When output mode is `Chosen Folder`, subfolder hierarchy relative to the dropped root folder is preserved (`~/Exports/marketing-site/img/hero.png`).

#### Flow D — Replace Original + Undo
1. **Explicit Trigger**: On a completed card with positive byte savings (`savedBytes > 0`), user clicks **Replace** (`arrow.2.squarepath`) or presses `⌘R` on a focused card (or `Replace All Originals` on a batch header).
2. **Atomic Trash-and-Swap**:
   - App stages a recovery reference, calls `FileManager.default.trashItem(at: originalURL, resultingItemURL: &trashedURL)`, and moves the compressed file to `originalURL` (if format conversion changed the extension, e.g. `.png` → `.avif`, original `.png` moves to Trash, `.avif` lands in the same parent folder, and card label notes `Replaced .png → .avif`).
   - Card badge updates to `Replaced original` (`checkmark.circle.fill`) and Replace action disables.
3. **Undo (`⌘Z`)**: An inline bottom toast appears inside the Tray for `6.0 s`: `"Replaced hero@2x.png (original moved to Trash)  [Undo ⌘Z]"`. Pressing `⌘Z` (even after toast auto-hides, for the remainder of the app session) moves `trashedURL` back to `originalURL`, restores the compressed output back to its suffixed path (`hero@2x-min.png`), and reverts the card state. If the user already emptied Trash externally, Undo shows inline warning `"Original no longer in Trash"`.

#### Flow E — Non-Blocking Error Handling
1. **Per-File Errors**: Unsupported UTIs, corrupted headers, or read-only single files mark *only* that card as `Error` (coral tint badge + concise reason + contextual recovery CTA), while sibling parallel jobs finish normally.
   - *Unsupported format*: `"Unsupported (.sketch) — skipped"` (auto-dismisses after `3.5 s` on Dropzone if single file; muted row in Tray).
   - *Permission / Sandbox denied*: `"No write permission in folder"` + `[Choose Output…]` button opening `NSOpenPanel` to grant security-scoped bookmark or save elsewhere.
   - *Corrupt input*: `"Unreadable image data"` + `[Reveal]` button.
2. **System-Wide Disk Full (`ENOSPC`)**: Immediately pauses pending queue items, cleans up partial `.tmp` files, displays a persistent coral banner in Tray header (`"Disk full — paused 14 remaining jobs"` + `[Resume]` / `[Cancel Queue]`), and shakes Dropzone horizontally (`±6 pt`, `240 ms`) if Tray is closed.

---

## 2. Surface Architecture, Layout & Visual System

### 2.1 Menu Bar Anchor (`NSStatusItem`)
- **Width**: Variable (`28 pt` idle; `68 pt` when showing optional live batch `%` while both surfaces are closed).
- **Icon**: Custom template vector (`16 × 16 pt` optical frame, `1.5 pt` stroke) depicting two inward-converging logarithmic brackets compressing a dot; animates subtle inward pulse (`scale 0.88 ↔ 1.0`, `1.2 s`) + circular `14 pt` progress arc around glyph when jobs run with Dropzone/Tray hidden.
- **Interactions**:
  - **Left-click**: Toggles Tray on current screen.
  - **Right-click / `⌃`-click**: Opens native `NSMenu`: `Open Tray (⌃⌥Space)`, separator, `Default Mode: Smart / Lossless`, `Pin Dropzone Puck`, separator, `Settings… (⌘,)`, `Quit Logn (⌘Q)`.
  - **Drag-and-Drop onto Status Item**: Always accepts file drops using current default mode and pops a Dropzone Done Pill directly below the status item (`statusItem.button.window.frame`).

### 2.2 Surface 1: Dropzone Specification

#### Default Appearance Decision: Drag-Summoned (Not Always-Visible Puck)
- **Decision**: **Appear-on-Drag** is the shipping default; **Always-Visible Mini Puck** (`40 × 40 pt` edge-snapped squircle) is an opt-in toggle in Settings.
- **Justification**: Compression is an episodic utility. An always-on floating widget permanently occludes content, competes with window traffic lights/scrollbars, and pushes users to quit the app. Watching `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp])` and checking `NSPasteboard(name: .drag).changeCount` *once* after a `24 pt` drag threshold costs `0%` idle CPU, ignores text/window-resize drags, and ignores drags initiated from Logn's own result cards (`pasteboard` custom marker `codes.t3.ologn.selfDrag`).

#### Anchor Position & Geometry
- **Default Anchor**: **Top-Center of the cursor's active `NSScreen`**, horizontally centered at `screen.frame.midX`, top edge positioned at `screen.visibleFrame.maxY - 10 pt`.
  - *Notch & Menu Bar Clearance*: On notched 14"/16" MacBook Pros, `screen.visibleFrame.maxY` sits directly beneath the camera housing (`~37–38 pt` from physical top). Subtracting `10 pt` guarantees clearing both the hardware notch and menu bar on all Macs while staying away from the bottom Dock and bottom Tray.
  - *User Repositioning*: `⌘`-dragging the Dropzone lets the user snap it to **Top-Center** (default), **Left-Center** (`visibleFrame.minX + 10 pt`), or **Right-Center** (`visibleFrame.maxX - 10 pt`); persisted per display UUID.
- **Hit-Window Frame**: Fixed `304 × 96 pt` transparent `NSPanel` container so spring scale/expansion animations never clip or reallocate window backing stores mid-gesture.

#### Dimensions & Internal Layout
| Dropzone Phase | Pill Size (`W × H`) | Corner Radius | Outer Padding | Internal Anatomy |
| :--- | :--- | :--- | :--- | :--- |
| **Pinned Puck** *(opt-in)* | `40 × 40 pt` | `12 pt` (continuous) | — | Centered `18 pt` app glyph at `75%` opacity; expands to `280 × 76 pt` on drag or hover. |
| **Drag-Summoned Idle** | `228 × 60 pt` | `30 pt` (capsule) | `6 pt` | Two equal `105 × 48 pt` halves separated by `6 pt` gap (`1 pt × 24 pt` centered divider hairline). |
| **Proximity / Hover** *(<96 pt)* | `280 × 76 pt` | `38 pt` (capsule) | `6 pt` | Two `131 × 64 pt` halves (`6 pt` gap). Active half scales to `1.03×` with tinted glass fill; inactive half dims to `0.62` opacity. |
| **Compressing** | `216 × 52 pt` | `26 pt` (capsule) | `12 pt` H / `10 pt` V | Left `24 × 24 pt` ring (`3 pt` stroke); center stack (`13 pt` title + `11.5 pt` SF Mono ticker); right `20 × 20 pt` hover `xmark` cancel button. |
| **Done / Optimal** | `236 × 56 pt` | `28 pt` (capsule) | `10 pt` H / `10 pt` V | Left `36 × 36 pt` draggable thumbnail (`8 pt` radius); center stack (`−64%` pill + `11.5 pt` saved bytes); right `24 × 24 pt` `chevron.down` Tray button. |

#### Zero-Click Mode Selection Mechanic
- **Left Half = `Smart`** (Lossy perceptual optimization: MozJPEG/libjpeg-turbo perceptual, pngquant+oxipng, WebP/AVIF/HEVC perceptual). Icon: `sparkles` (`15 pt` Semibold), Title: `Smart`, Subcaption: `Smallest`.
- **Right Half = `Lossless`** (Bit-exact / pixel-exact: oxipng/zopfli, lossless JPEG Huffman/arithmetic transcode, lossless WebP, metadata preserved unless opted out). Icon: `checkmark.shield` (`15 pt` Semibold), Title: `Lossless`, Subcaption: `Bit-exact`.
- **Seam Tie-Breaker**: Dropping on the exact `6 pt` center seam defaults to the user's last-used mode (initial default: `Smart`).
- **Modifier Keys During Drag**:
  - Hold **`⌥` (Option)**: Flips the targeted half (`Smart ↔ Lossless`) in place and shows a `⌥` keycap badge—ideal for fast flick-drops without horizontal aiming.
  - Hold **`⇧` (Shift)**: Drops items and immediately slides open the **Tray** with those items focused.

### 2.3 Surface 2: Bottom Tray Specification

#### Geometry, Margins & `frame` vs `visibleFrame` Decision
- **Horizontal Layout Decision**: **Inset Floating Shelf** (`12 pt` left, right, and bottom margins; `maxWidth: 1360 pt` centered horizontally on wide displays).
  - *Why Inset over Full-Bleed*: Full-bleed edge-to-edge slabs fight macOS 26's concentric floating-glass language, clip corner radii awkwardly against rounded MacBook display corners, and scatter UI controls `5000 px` apart on ultrawide monitors. A `12 pt` margin with `22 pt` continuous corner radius matches MacBook screen bezel curvature and frames Liquid Glass edge refraction cleanly.
- **Height Formula**: `trayHeight = round(clamp(screen.frame.height * 0.255, min: 248, max: 360))` pt (~25% of screen height).
- **`frame` vs `visibleFrame` & Dock Rule**:
  - **Bottom Edge (`minY`)**: Anchored to **`screen.frame.minY + 12 pt`** at window level `NSPanel.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)`. When the macOS Dock is visible at the bottom, the Tray **slides cleanly over the Dock** rather than floating `85 pt` up the screen (which would push a 25%-tall tray near the vertical midpoint of a 13" laptop). Dismissing the Tray immediately uncovers the Dock.
  - **Left / Right Edges (`minX` / `maxX`)**: Anchored within **`screen.visibleFrame.minX + 12 pt`** and **`screen.visibleFrame.maxX - 12 pt`**. If the user keeps their Dock pinned on the Left or Right screen edge, the Tray respects the side Dock's `visibleFrame` inset so both remain simultaneously usable.
- **Fullscreen Apps & Spaces Behavior**:
  - `panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
  - Summoning via `⌃⌥Space` or status item opens the Tray directly **over active native fullscreen Spaces** (e.g., Keynote, Final Cut Pro, fullscreen Safari) on whichever `NSScreen` currently holds the pointer—never triggering a Space swipe back to Desktop. Switching Spaces while open moves the Tray with the active Space; entering Mission Control hides it cleanly via `.transient`.

#### Internal 3-Zone Tray Layout
Outer padding: `12 pt` all sides. Corner radius: `22 pt` (`.continuous`).

1. **Zone A — Top Control Bar (`40 pt` height, `8 pt` bottom spacing)**:
   - **Left Cluster (`8 pt` H-gap)**:
     - **Mode Segmented Control (`156 × 30 pt`)**: `Smart` | `Lossless` (`capsule` selection indicator).
     - **Quality Preset Pill (`104 × 30 pt`)**: Shown in `Smart` mode: cycles or pops menu `Balanced` *(default, ~Q80)* / `Compact` *(max shrink, ~Q68)* / `Studio` *(high fidelity, ~Q90)*. In `Lossless` mode, collapses smoothly to a muted `Bit-exact` lock pill.
     - **Format Convert Pill (`116 × 30 pt`)**: `Keep Format` *(default)* vs opt-in menu: `Images → AVIF`, `Images → HEIC`, `Images → WebP`. Active conversion highlights pill in accent tint (`arrow.right.circle.fill`).
     - **Output Destination Pill (`max 190 × 30 pt`)**: Menu toggle between `Next to file (-min)` *(default)* and `Folder: <Name>…` (click folder name to reveal; `Choose Folder…` opens `NSOpenPanel`).
   - **Right Cluster (`10 pt` H-gap)**:
     - **Aggregate Savings Stat**: `"Saved 1.24 GB today"` (click cycles `Today` → `This Week` → `All Time: 18.6 GB`) in tabular SF Mono `12 pt` Medium.
     - **Clear Done Button (`68 × 28 pt`)**: Enabled when `≥ 1` finished card exists; clears finished/error cards from view without touching files on disk.
     - **Settings Toggle (`30 × 30 pt` circular button)**: `gearshape` (`14 pt`); toggles inline Settings view (`⌘,`).

2. **Zone B — Split Workspace (`trayHeight - 72 pt` height; `184 pt` on 13", `288 pt` on 27")**:
   - **Left Intake Well (`224 pt` width on `<1600 pt` screens; `264 pt` on `≥1600 pt` screens)**:
     - `14 pt` continuous corner radius, `1.5 pt` dashed inner border (`separatorColor` at `45%` opacity; solid `2 pt` accent border on drag-hover).
     - Centered `28 pt` `arrow.down.doc` symbol, primary prompt `"Drop files or folders"`, secondary caption `"Click to browse · ⌘V paste"`.
     - Bottom live status strip (`24 pt` height) when engine active: `bolt.horizontal.fill` + `"4 threads · 210 MB/s"` + `[Cancel All]` text button.
   - **Right Queue & History List (`flexible width`, `10 pt` gap from Intake Well)**:
     - Vertical `ScrollView` (`6 pt` inter-card vertical spacing, `4 pt` right scroller inset). Fits **3 full cards** (`56 pt` height each) cleanly on a 13" MacBook Air (`184 pt` workspace) and **4–5 cards** on 16"/27" displays.
     - **Job Card Anatomy (`height: 56 pt`, `cornerRadius: 12 pt` continuous, `10 pt` H-padding)**:
       - **Col 1 — Thumbnail (`38 × 38 pt`, `8 pt` radius)**: Async `QLThumbnailGenerator` preview (falls back to native UTI file icon). Acts as an `NSDraggingSource` once completed so users can drag the compressed file straight out of the card.
       - **Col 2 — File & Codec Stack (`flex`, min `160 pt`)**:
         - Row 1: Middle-truncated filename (`hero-banner@2x.png`, `13 pt` Semibold) + optional parent-folder chip (`img/`) when part of a folder drop.
         - Row 2: Codec & method summary (`PNG · Lossless · oxipng` or `JPEG · Smart Balanced · −64%`), `11.5 pt` secondary label.
       - **Col 3 — Size Delta (`148 pt` right-aligned tabular block)**:
         - `14.8 MB → 5.3 MB` in SF Mono `12 pt` Regular (`14.8 MB` secondary, `→` tertiary, `5.3 MB` primary). During compression, shows determinate `96 × 4 pt` capsule progress bar + `68%`.
       - **Col 4 — Savings Badge (`76 pt` fixed width, right-aligned)**:
         - `24 pt` tall capsule pill: e.g. `−64%` (emerald fill `16%` + emerald text), `Optimal` (neutral fill + secondary text), `Cancelled`, or `Failed`.
       - **Col 5 — Quick Actions Cluster (`116 pt` width; visible on card hover or keyboard selection; collapses when idle to keep rows clean)**:
         - Four `26 × 26 pt` icon buttons (`6 pt` radius, tooltip on `400 ms` hover):
           1. **Reveal in Finder** (`folder`, `↩`)
           2. **Copy File** (`doc.on.doc`, `⌘C`)
           3. **Replace Original** (`arrow.2.squarepath`, `⌘R` — moves original to Trash; disabled if `Already optimal` or already replaced)
           4. **Remove / Cancel** (`xmark` — cancels if running; removes card from list if done, `⌘⌫`)

3. **Zone C — Inline Settings View (Replaces Zone B in-place when `gearshape` active)**:
   - Header’s `gearshape` turns accent-filled with a `Done` (`↩` / `Esc`) pill beside it. Zone B transitions via Z-axis depth crossfade into a **3-Column Settings Grid** (`12 pt` column gap, `14 pt` continuous corner radius per column platter, `12 pt` internal padding).
   - **13" Height Budget (`176 pt` minimum workspace)**: Each column holds **at most 4 compact control rows** (`28 pt` row height, `8 pt` vertical row gap → `136 pt` content inside `152 pt` inner height) so Settings never requires vertical scrolling even on a `956 pt`-tall 13" MacBook Air:
     - **Col 1 — Presence & Input**: (1) Global Hotkey Recorder (`⌃⌥Space` + `Reset`), (2) Dropzone Mode (`On file drag` [default] / `Always-on puck` / `Off`), (3) Launch at Login toggle, (4) Haptics & Sound (`Haptics ON` · `Sound OFF` pills).
     - **Col 2 — Compression Engine**: (1) Default Smart Quality (`Compact` / `Balanced` / `Studio`), (2) Strip EXIF/GPS (`Smart: ON` · `Lossless: OFF` by default so Lossless remains bit/metadata-preserving unless opted in), (3) Preserve file timestamps (`ON`), (4) Worker threads (`Auto — P-Cores`).
     - **Col 3 — Output & Hygiene**: (1) Filename suffix (`{name}-min.{ext}` [default], `{name}.opt.{ext}`), (2) Folder structure (`Mirror tree` [default] / `Flatten`), (3) History retention (`On Quit` / `24h` / `7 days` [default]), (4) Footer actions (`Skip dotfiles: ON` + `Reset Stats…`).

#### Drag-Out, Self-Drag Guard & Clipboard Intake Contract
- **Self-Drag Exclusion**: Every outbound drag from a Dropzone Done Pill or Tray Job Card writes an empty marker item for custom pasteboard type `UTType(exportedAs: "codes.t3.ologn.self-drag")` onto `NSPasteboard(name: .drag)`. The global drag monitor ignores any drag session carrying this marker so dragging compressed files *out* of Logn never re-summons the Dropzone.
- **Multi-File Drag-Out**: When a Dropzone batch (`N > 1`) completes, the `36 × 36 pt` stacked thumbnail acts as a multi-item `NSDraggingSource` writing all `N` compressed output `NSURL`s (`NSPasteboardWriting`), with a system count badge (`N`).
- **Clipboard `⌘V` Intake**: Pressing `⌘V` inside the Tray checks `NSPasteboard.general` in priority order: (1) file URLs (`public.file-url`) → compressed according to current Output Destination; (2) raw bitmap/image data (`public.png`, `public.tiff` from `⇧⌃⌘4` screenshots) → materialized as `Clipboard-YYYY-MM-DD-HHmmss.png` inside the configured Export Folder (or `~/Downloads` if Output is `Next to file`) and compressed immediately.

### 2.4 Screen-Size Adaptation Matrix
| Display Class | Logical Resolution | Tray Width × Height | Intake Well | Card List Layout | Dropzone Top Anchor |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **13" MacBook Air** | `1470 × 956 pt` | `1446 × 248 pt` *(25.9%)* | `224 pt` | 1-col stack (3 visible `56 pt` cards) | `visibleFrame.maxY - 10 pt` |
| **14" / 16" MacBook Pro (Notch)** | `1512 × 982` / `1728 × 1117 pt` | `1488 × 256` / `1704 × 285 pt` | `236 pt` | 1-col stack (3.5–4 visible cards) | `visibleFrame.maxY - 10 pt` *(clears `38 pt` notch)* |
| **27" 5K Studio Display** | `2560 × 1440 pt` | **`1360 × 360 pt`** *(capped W, 25.0% H)* | `264 pt` | 1-col wide cards (5 visible cards) | `visibleFrame.maxY - 12 pt` (centered on screen) |
| **34"+ Ultrawide / Pro Display** | `3440 × 1440 pt`+ | **`1360 × 360 pt`** *(centered on cursor X clamped to screen)* | `264 pt` | 1-col wide cards (5 visible cards) | Centered on `clamp(cursorX, minX+240, maxX-240)` so user doesn't drag `1700 pt` sideways! |

> **Ultrawide Ergonomic Rule**: When `screen.frame.width > 2800 pt`, both the summoned Dropzone and the `1360 pt` Tray center horizontally on **the cursor's X position at summon time** (clamped `12 pt` inside `visibleFrame` edges) instead of `screen.frame.midX`, eliminating multi-foot horizontal mouse travel.

### 2.5 Typography, SF Symbols & Color/Material System

#### Concentric Radii & Spacing Scale
- **Spacing Rhythm**: Strict `4 pt` base grid (`4 / 6 / 8 / 10 / 12 / 16 pt`).
- **Concentric Radii**: Tray outer `22 pt` − `10 pt` inset = `12 pt` Job Card radius (`14 pt` Intake Well); Card `12 pt` − `4 pt` optical inset = `8 pt` Thumbnail radius; Dropzone pills use continuous `.capsule` (`height / 2`).

#### Typography Scale
All numeric byte counts, percentages, speeds, and progress figures **must** apply `.monospacedDigit()` or `SF Mono` to prevent horizontal jitter during live updates.

| Token | Font Family | Size / Weight | Line Height | Usage |
| :--- | :--- | :--- | :--- | :--- |
| `dropzone.mode` | SF Pro Text | `14 pt` Semibold | `18 pt` | Dropzone `Smart` / `Lossless` titles |
| `dropzone.sub` | SF Pro Text | `11 pt` Medium | `14 pt` | Dropzone subcaptions (`Smallest`, `Bit-exact`) |
| `tray.control` | SF Pro Text | `12.5 pt` Medium | `16 pt` | Top bar segmented control, pills, buttons |
| `card.filename` | SF Pro Text | `13 pt` Semibold | `17 pt` | Job card filename (`.lineBreakMode = .byTruncatingMiddle`) |
| `card.meta` | SF Pro Text | `11.5 pt` Regular | `15 pt` | Codec string (`PNG · Lossless · oxipng`), status subtext |
| `metric.mono` | **SF Mono** | `12 pt` Medium | `16 pt` | Before → after sizes (`14.8 MB → 5.3 MB`), speed, daily total |
| `badge.delta` | **SF Mono** | `11.5 pt` Bold | `14 pt` | Savings pill (`−64%`), progress `%`, Dropzone live ticker |
| `toast.body` | SF Pro Text | `12.5 pt` Medium | `16 pt` | Undo banner & inline error messages |

#### Verified SF Symbols Inventory
| UI Element | SF Symbol Name | Rendering Mode | Size / Weight |
| :--- | :--- | :--- | :--- |
| Smart Mode | `sparkles` | `.hierarchical` | `14–15 pt` Semibold |
| Lossless Mode | `checkmark.shield` | `.hierarchical` | `14–15 pt` Semibold |
| Intake Well Prompt | `arrow.down.doc` | `.hierarchical` | `28 pt` Regular |
| Format Conversion Active | `arrow.right.circle.fill` | `.multicolor` / Accent | `13 pt` Medium |
| Output Folder | `folder` | `.monochrome` | `13 pt` Medium |
| Settings Toggle | `gearshape` / `gearshape.fill` | `.monochrome` | `14 pt` Medium |
| Reveal in Finder | `magnifyingglass` *(or `folder`)* | `.monochrome` | `13 pt` Medium |
| Copy to Clipboard | `doc.on.doc` | `.monochrome` | `13 pt` Medium |
| Replace Original | `arrow.2.squarepath` | `.monochrome` | `13 pt` Medium |
| Undo Action | `arrow.uturn.backward` | `.monochrome` | `12 pt` Semibold |
| Cancel / Remove | `xmark` | `.monochrome` | `11 pt` Bold |
| Already Optimal | `equal.circle` | `.hierarchical` | `13 pt` Medium |
| Error Warning | `exclamationmark.triangle.fill` | `.palette` (White, Coral) | `13 pt` Medium |
| Parallel Throughput | `bolt.horizontal.fill` | `.hierarchical` | `11 pt` Semibold |

#### Materials, Light/Dark Palette & Accent Policy
- **Primary Material (macOS 26 Liquid Glass)**:
  - **Dropzone**: `GlassEffectContainer(spacing: 10)` wrapping pill elements with `.glassEffect(.regular.interactive(), in: .capsule)` and `@Namespace` `.glassEffectID` transitions.
  - **Tray**: Root container uses `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))` backed by an `NSPanel` with `backgroundColor = .clear` and `isOpaque = false`.
  - **Job Cards**: Subtle elevated platter over glass: Light `rgba(255, 255, 255, 0.52)`, Dark `rgba(255, 255, 255, 0.07)` with `0.5 pt` inner border (`rgba(255, 255, 255, 0.14)` dark / `rgba(0, 0, 0, 0.06)` light); hovered/selected card lifts to `0.74` light / `0.13` dark.
  - **Fallback (`Reduce Transparency` ON)**: Replaces `.glassEffect` with opaque `NSColor.windowBackgroundColor` (`#F5F5F7` Light / `#1E1E20` Dark), cards `#FFFFFF` Light / `#2A2A2D` Dark, and `1 pt` `NSColor.separatorColor` borders.

```swift
// Illustrative macOS 26 Liquid Glass + Reduce Transparency surface modifier
struct AdaptiveGlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}
```

- **Semantic Tokens (Light / Dark)**:
  - **Savings Emerald** *(reserved strictly for positive byte reduction)*: Text `#0A7B3E` (Light) / `#34D399` (Dark); Pill fill `rgba(16, 185, 129, 0.15)` (Light) / `rgba(52, 211, 153, 0.18)` (Dark).
  - **Optimal Neutral**: Text `NSColor.secondaryLabelColor`; Pill fill `quaternaryLabelColor`.
  - **Warning Amber** *(disk space / permissions)*: Text `#B45309` (Light) / `#FBBF24` (Dark); Fill `16%` opacity.
  - **Error Coral**: Text `#C22727` (Light) / `#F87171` (Dark); Fill `16%` opacity.
  - **System Accent Color (`Color.accentColor`)**: Used for keyboard focus rings (`2 pt`), active segmented control/toggle states, Intake Well active drag border, and active progress ring/bars—honoring the user's macOS Multicolor/Graphite/Blue/Purple preference without muddying semantic emerald savings badges.

---

## 3. Exhaustive Surface States & Copy

### 3.1 Dropzone State Machine
| State | Trigger | Visual Presentation | Exact UI Copy |
| :--- | :--- | :--- | :--- |
| **1. Dormant** | Idle (default mode) | Panel hidden (`orderOut(nil)`), `0` GPU surfaces allocated. | — |
| **2. Drag-Summoned Idle** | Global file drag `≥24 pt`, pointer `>96 pt` away | `228 × 60 pt` glass capsule slides down `10 pt` below menu bar/notch; equal neutral halves. | Left: `Smart` / `Smallest` · Right: `Lossless` / `Bit-exact` |
| **3. Drag-Hover: Smart** | Drag pointer inside Left half *(or Right + `⌥`)* | Expands `280 × 76 pt`; Left half scales `1.03×` with accent tint glow; Right dims `62%`. | Left: `Smart` / `Drop to shrink` · Right: `Lossless` |
| **4. Drag-Hover: Lossless** | Drag pointer inside Right half *(or Left + `⌥`)* | Expands `280 × 76 pt`; Right half scales `1.03×` with accent tint glow; Left dims `62%`. | Left: `Smart` · Right: `Lossless` / `Drop exact` |
| **5. Compressing (Single)** | 1 file dropped | Morphs to `216 × 52 pt` capsule; `24 pt` determinate ring; hover reveals `xmark` cancel. | Line 1: `hero@2x.png` · Line 2: `Smart · 64%` |
| **6. Compressing (Batch)** | `N > 1` files or folder dropped | Same `216 × 52 pt` capsule; ring tracks byte-weighted overall completion; live saved ticker. | Line 1: `18 files (6 left)` · Line 2: `−42.6 MB so far` |
| **7. Done (Savings)** | Job/batch finishes with `savedBytes > 0` | `236 × 56 pt` capsule; `36 pt` draggable thumbnail/stack; emerald pill; `6.0 s` dwell (paused on hover). | Pill: `−64%` · Sub: `Saved 9.5 MB · Drag or click` |
| **8. Already Optimal** | `outputBytes >= inputBytes` | `236 × 56 pt` capsule; `equal.circle` icon; neutral badge; `4.0 s` dwell. No duplicate `-min` written. | Pill: `Already optimal` · Sub: `0 B saved · Original kept` |
| **9. Error / Cancelled** | Unsupported UTI, unreadable, or user hit `xmark` | `236 × 52 pt` capsule; coral warning icon (or neutral for cancel); `4.0 s` dwell (or `1.8 s` for cancel). | Error: `Unsupported (.dmg)` or `Read failed · Open Tray` · Cancel: `Cancelled` |

### 3.2 Tray & Job Card State Machine
| State | Scope | Visual Presentation & Behavior | Exact UI Copy |
| :--- | :--- | :--- | :--- |
| **1. Empty Idle** | Queue empty | Left Intake Well full height; Right pane shows centered muted onboarding hint (`48%` opacity). | Well: `Drop files or folders` / `Click to browse · ⌘V paste` · Right: `No recent jobs · Drop anywhere or press ⌘V` |
| **2. Tray Drag-Hover** | File drag enters Tray bounds | Intake Well border turns `2 pt` solid `accentColor` with `10%` tint fill; split pill inside Well lets user drop directly on `Smart` or `Lossless` (or anywhere else in Tray to use selected Top Bar mode). | Well: `Drop for Smart (Balanced)` *(updates live if hovering `Lossless` chip or holding `⌥`)* |
| **3. Queued** | Waiting for worker slot | Card at `82%` opacity; Col 3 shows subtle pulsing dot; `xmark` cancels before start. | Meta: `PNG · Smart · Queued` · Badge: `Waiting` |
| **4. Compressing** | Active on worker thread | Col 3 shows `96 × 4 pt` determinate capsule bar + speed; Col 4 shows `%` in SF Mono; Col 5 shows `xmark`. | Meta: `MP4 · Smart HEVC · 38 MB/s` · Badge: `47%` |
| **5. Done (Saved)** | Finished with savings | Full opacity; Col 3 shows `Before → After`; Col 4 emerald `−XX%` pill; Col 5 unlocks Reveal, Copy, Replace, Remove; thumbnail becomes draggable file source. | Meta: `PNG · Lossless · oxipng` (or `PNG → AVIF · Smart`) · Size: `14.8 MB → 5.3 MB` · Badge: `−64%` |
| **6. Already Optimal** | `output >= input` | Full opacity; Col 3 shows single size `2.1 MB`; Col 4 neutral pill; **Replace Original disabled** (`opacity 0.3`). Next-to-original creates no `-min` clutter; Export-folder copies untouched. | Meta: `JPEG · Smart · No smaller output possible` · Size: `2.1 MB` · Badge: `Optimal` |
| **7. Replaced Original** | User clicked Replace (`⌘R`) | Badge swaps to emerald `checkmark.circle.fill` + `−64%`; Meta appends `· Replaced`; Undo toast pops for `6.0 s`. | Meta: `PNG · Lossless · Replaced original` · Toast: `Replaced hero@2x.png (original in Trash)  [Undo ⌘Z]` |
| **8. Cancelled** | User clicked `xmark` / `⌘.` | `.tmp` artifact deleted immediately; card dims to `60%` opacity; Col 5 swaps Replace for `[Retry]` (`arrow.clockwise`). | Meta: `Cancelled — original untouched` · Badge: `Stopped` |
| **9. Error** | Codec / I/O failure | Subtle `1 pt` coral border; Col 3 shows specific cause; Col 5 shows contextual action (`[Choose Folder…]` or `[Retry]`). | Meta: `Permission denied in /Applications` · Badge: `Failed` |

---

## 4. Motion, Haptics & Sound

### 4.1 Spring & Timing Parameters
SwiftUI `Spring(response:dampingRatio:)` (and matching `CASpringAnimation` equivalents for `NSPanel` frame/alpha drivers):

| Transition | Curve / Spring | Properties Animated | Notes |
| :--- | :--- | :--- | :--- |
| **Dropzone Summon** | `Spring(response: 0.28, dampingRatio: 0.82)` | `y: -24 → 0 pt`, `scale: 0.86 → 1.0`, `opacity: 0 → 1` (`110 ms`) | Anchored from top center so it drops smoothly out of the menu bar/notch plane. |
| **Dropzone Proximity / Half Aim** | `Spring(response: 0.22, dampingRatio: 0.78)` | Pill frame `228×60 ↔ 280×76`, active half `scale: 1.03` | Interactive—tracks continuous cursor movement without lag. |
| **Dropzone Morph (Drop → Run → Done)** | `Spring(response: 0.32, dampingRatio: 0.86)` | `GlassEffectContainer` matched geometry + content crossfade (`140 ms`) | Zero window teardown; fluid liquid-glass coalescence of the two halves into one capsule. |
| **Dropzone Dismiss** | `Spring(response: 0.20, dampingRatio: 0.96)` | `y: 0 → -16 pt`, `scale: 1.0 → 0.90`, `opacity: 1 → 0` | Critically damped—snaps away cleanly with zero bounce. |
| **Tray Open** | `Spring(response: 0.30, dampingRatio: 0.86)` | `y: -(trayHeight + 16) → 0 pt`, `opacity: 0 → 1` (`90 ms`) | Subtle overshoot (`< 2.5 pt`) conveys tactile mass without sluggishness. |
| **Tray Close** | `Spring(response: 0.21, dampingRatio: 0.98)` | `y: 0 → -(trayHeight + 16) pt`, `opacity: 1 → 0` (`150 ms`) | Fast exit (`~210 ms` perceptual completion) so user gets screen back instantly. |
| **Card Insertion** | `Spring(response: 0.26, dampingRatio: 0.85)` | `y: -12 → 0 pt`, `opacity: 0 → 1`, list push-down | **Batch Stagger Cap**: Stagger `18 ms` per card for first `6` cards (`108 ms` max); cards `7…N` insert simultaneously to prevent layout waterfalls on 500-file drops. |
| **Settings Inline Swap** | `Spring(response: 0.24, dampingRatio: 0.90)` | Outgoing `scale: 0.97, opacity: 0`; Incoming `scale: 1.03 → 1.0, opacity: 1` | Tray outer frame stays `100%` rock-steady. |

### 4.2 Tickers & Progress Rings
- **Numeric Tickers**: Apply `.contentTransition(.numericText(countsDown: true))` on byte sizes and aggregate totals, **throttled to `15 Hz` (`66 ms` cadence)**. Updating rolling digits at `120 Hz` ProMotion blurs numerals into unreadable ghosts; `15 Hz` keeps every tick legible and crisp.
- **Determinate Progress Ring (`24 × 24 pt`, `3 pt` stroke, `.round` lineCap)**: Interpolates `trim(from: 0, to: progress)` with linear `80 ms` animation. Only if initial directory enumeration exceeds `150 ms` does an indeterminate `270°` arc rotate (`1.0 s` linear) before locking onto `0% → 100%`.

### 4.3 Haptics (`NSHapticFeedbackManager`) & Micro-Audio
Triggered via `NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime: .now)` (automatically no-ops on mice without Force Touch trackpads):
- **Cross into Smart or Lossless drop half (or toggle `⌥`)**: `.alignment` (crisp tactile detent confirming mode selection without looking).
- **Release mouse to drop files**: `.levelChange`.
- **Job or batch completion (`savedBytes > 0`)**: `.generic` (fired **once per batch**, never per file in a 100-file folder drop!).
- **Optional Sound (`OFF` by default or `ON` subtle, toggle in Settings)**: Custom `45 ms` warm wooden-glass tick (`-20 dBFS`) on drop acceptance and a `110 ms` soft harmonic fifth (`-18 dBFS`) on batch completion. Automatically muted if macOS system alert volume is `0` or Focus/DND is active.

### 4.4 Reduce Motion & Reduce Transparency
- **`accessibilityDisplayShouldReduceMotion == true`**:
  - Disables all vertical slide translations (`y` deltas set to `0`), proximity size expansion (Dropzone summons directly at `280 × 76 pt`), card stagger, and `.numericText` rolling digits.
  - Replaces all show/hide/settings transitions with a `140 ms` linear opacity crossfade.
- **`accessibilityDisplayShouldReduceTransparency == true`**:
  - Swaps all `.glassEffect` modifiers for solid semantic `windowBackgroundColor` / `controlBackgroundColor` fills with crisp `1 pt` `separatorColor` borders.

---

## 5. Keyboard & Global Shortcut Specification

### 5.1 Default Global Hotkey: `⌃⌥Space` (Control + Option + Space)
- **Justification**:
  - `⌘Space` is macOS Spotlight; `⌥⌘Space` is Finder Search; `⌃Space` is macOS Input Source switching; `⌥Space` is the universal Raycast/Alfred/ChatGPT launcher slot.
  - Letter chords like `⌥⌘K` or `⇧⌘C` collide routinely with Safari/VS Code/Slack/Figma/Xcode shortcuts (`Insert Link`, `Format`, `Inspect`, `Colors`).
  - **`⌃⌥Space`** is unbound in stock macOS, conflicts with virtually zero pro creative or developer apps, sits naturally under left pinky + thumb without moving hands off home row, and echoes launcher muscle memory. Customizable via the inline Settings hotkey recorder.

### 5.2 Complete Tray Keymap
| Shortcut | Context | Action |
| :--- | :--- | :--- |
| **`⌃⌥Space`** | Global (anywhere in macOS) | Toggle Tray open / closed on cursor's screen |
| **`Esc`** | Tray open | 1) Close Quick Look if open → 2) Exit Settings view if open → 3) Dismiss Tray |
| **`↑` / `↓`** | Card list | Move selection up / down (`⌘↑` / `⌘↓` jumps to top / bottom card) |
| **`Space`** | Card selected | Toggle native `QLPreviewPanel` showing compressed file (title notes `Compressed · 5.3 MB (−64%)`) |
| **`↩` (Return)** | Card selected | Reveal output file in Finder |
| **`⌘C`** | Card selected | Copy compressed file URL to `NSPasteboard.general` (pasteable into Slack, Mail, Finder) |
| **`⌘V`** | Anywhere in Tray | Compress files or raw image data (`PNG`/`TIFF` screenshot) from clipboard immediately |
| **`⌘O`** | Anywhere in Tray | Open `NSOpenPanel` (allows files + directories, multiple selection) |
| **`⌘R`** | Completed card selected | **Replace Original** (moves original to Trash, enables `⌘Z`) |
| **`⌘Z`** | Anywhere in Tray | **Undo** last Replace Original (or restore last removed card) |
| **`⌘⌫`** | Completed / Error card | Remove card from history list (keeps files on disk; `⌥⌘⌫` moves output file to Trash) |
| **`⌘.`** *(or `⌫`)* | Active / Queued card | Cancel running compression job (`⇧⌘.` cancels all active jobs) |
| **`⌘1` / `⌘2`** | Anywhere in Tray | Switch active mode to `Smart` (`⌘1`) or `Lossless` (`⌘2`) |
| **`⌘,`** | Anywhere in Tray | Toggle inline Settings deck |

---

## 6. Accessibility

### 6.1 VoiceOver Roles, Labels & Batch Announcements
- **Pointer-Free Parity**: Users who cannot perform drag-and-drop have `100%` feature parity via **`⌃⌥Space` → `⌘V` (paste copied Finder files or clipboard image)** or **`⌃⌥Space` → `⌘O`**, selecting `Smart`/`Lossless` with `⌘1`/`⌘2`—completing any job in 3 keystrokes.
- **Dropzone Accessibility** (`NSAccessibilityRole.group`, sub-elements `.button` / drop targets):
  - Left Half Label: `"Drop zone: Smart compression, lossy perceptual, smallest file size"`.
  - Right Half Label: `"Drop zone: Lossless compression, bit-exact quality"`.
  - Done Pill Label: `"Compression complete. hero@2x.png, saved 64 percent, 9.5 megabytes. Press to reveal in Finder."`
- **Job Card Accessibility** (`accessibilityElement(children: .combine)`):
  - Label format: `"{filename}, {status}. {codecSummary}. {beforeSize} to {afterSize}, saved {percent}."` (e.g., `"hero-banner@2x.png, completed. PNG Lossless. 14.8 megabytes to 5.3 megabytes, saved 64 percent."`)
  - **`accessibilityCustomActions`** attached to every card so VoiceOver users never hunt hover buttons (`⌃⌥⌘Space` Actions menu): `Reveal in Finder`, `Copy Compressed File`, `Replace Original (Moves Original to Trash)`, `Preview with Quick Look`, `Remove from List` (or `Cancel Compression` while running).
- **Polite Progress Throttling**: During parallel batches, post `NSAccessibility.Notification.announcementRequested` with `.low` priority **only on batch start, every `5 s` milestone if >10 s long, and batch completion** (`"Finished compressing 42 files, saved 184 megabytes"`), never per-file or per-percentage tick.

### 6.2 Contrast & Visual Differentiation
- **Contrast Floor**: Primary text maintains `≥ 7:1` and secondary text/monospaced sizes maintain `≥ 4.5:1` WCAG AA contrast against Liquid Glass across extreme light/dark wallpapers via an internal `12%` adaptive backdrop tint scrim inside the glass material.
- **Increase Contrast (`accessibilityDisplayShouldIncreaseContrast`)**: Adds `1.5 pt` high-contrast borders around Tray, Dropzone halves, pills, and cards, and boosts emerald/coral text saturation.
- **Differentiate Without Color**: Status never relies on color alone—every badge pairs distinct shapes/icons/copy (`−64%` minus prefix, `equal.circle` + `Optimal`, `exclamationmark.triangle.fill` + `Failed`, `checkmark.circle.fill` + `Replaced`).

---

## 7. Window Level, Click-Through & Focus (`makeKey`) Rules

An accessory utility feels broken the instant it steals active focus from the user's editor or browser during a drag. Implement these exact AppKit `NSPanel` rules:

```swift
// Shared baseline for both DropzonePanel and TrayPanel (subclasses of NSPanel)
styleMask = [.borderless, .nonactivatingPanel]
isFloatingPanel = true
becomesKeyOnlyIfNeeded = true
hidesOnDeactivate = false
```

| Scenario | `NSApp` Active? | Panel `isKeyWindow`? | Click-Through / Event Routing Behavior |
| :--- | :--- | :--- | :--- |
| **Dropzone: Drag-Summoned / Running / Done** | **NO** | **NEVER** (`canBecomeKey == false`) | Frontmost app keeps focus + active menu bar + blinking text caret. Transparent outer margin of the `304 × 96 pt` panel sets `ignoresMouseEvents = true` outside the pill `CGPath` (updated on resize), or hit-tests `nil` in `NSView.hitTest(_:)`, so clicks `2 pt` outside the capsule pass straight through to windows underneath. Clicking Done Pill handles action via `acceptsFirstMouse(for:) -> true` without activating `NSApp`. |
| **Tray: Summoned via Hotkey (`⌃⌥Space`) or Status Item Click** | **NO** (`NSApp.activate` **not** called) | **YES** (`trayPanel.makeKey()`) | Calling `makeKey()` on a `.nonactivatingPanel` routes `Esc`, `↑`/`↓`, `Space`, `⌘V`, `⌘R`, and `⌘Z` directly to `TrayPanel` **while keeping the user's previous app frontmost** (no window titlebar dimming in Safari/Xcode, no menu bar flash). |
| **Tray: Summoned Passively** *(e.g. clicking `⌄` on Done Pill while typing elsewhere, or mouse-dragging into Tray)* | **NO** | **NO** until keyboard/text interaction | Interactive buttons (`Smart`/`Lossless`, `Reveal`, `Replace`) return `acceptsFirstMouse(for:) -> true` and execute on single click without stealing key focus. |
| **Tray: Typing in Settings** *(Hotkey Recorder or custom suffix text field)* | **NO** | **YES** (`makeFirstResponder`) | Clicking a text input inside Settings calls `trayPanel.makeKey()` and assigns first responder (`becomesKeyOnlyIfNeeded = true`). |
| **Click Outside Tray** | Unchanged | Resigns key & closes | Global + local `.leftMouseDown` / `.rightMouseDown` monitor detects clicks outside `trayPanel.frame` (and outside active `NSOpenPanel` / `QLPreviewPanel` / status item button), dismisses Tray immediately, and **lets the click pass through untouched** to the underlying window. *(Exception: if `NSOpenPanel` is open for folder selection, auto-dismiss is suspended until the sheet closes.)* |

---

## 8. ASCII Wireframes

### 8.1 Dropzone — Drag-Summoned Idle vs. Drag-Hover (Smart Half Targeted)

```text
[A] DRAG-SUMMONED IDLE (Cursor > 96 pt away · 228 × 60 pt capsule · 10 pt below menu bar/notch)
═════════════════════════════════════════════ Menu Bar / Notch ═════════════════════════════════════════════
                                      ╭──────────────┬──────────────╮
                                      │ ✦ Smart      │ ⛨ Lossless   │
                                      │   Smallest   │   Bit-exact  │
                                      ╰──────────────┴──────────────╯

[B] DRAG-HOVER: LEFT HALF TARGETED (Cursor < 96 pt, inside Left half · 280 × 76 pt expanded capsule)
                                 ╭═══════════════════╤───────────────────╮
                                 ║  ✦ SMART          │   ⛨ Lossless      ║
                                 ║    Drop to shrink │     Bit-exact     ║
                                 ║    [⌥ Lossless]   │    (dimmed 62%)   ║
                                 ╰═══════════════════╧───────────────────╯
                                           ▲
                                      [📄×3 cursor]

[C] DONE STATE (236 × 56 pt · dwells 6.0 s · thumbnail is drag-out source · click body reveals in Finder)
                                     ╭─────────────────────────────────╮
                                     │ [🖼]  [−64%]  Saved 9.5 MB   ⌄  │
                                     │       Drag out or click         │
                                     ╰─────────────────────────────────╯
```

### 8.2 Bottom Tray — Live Queue & History (3 Example Cards)

```text
╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│  [ ✦ Smart | ⛨ Lossless ]  [ Balanced ▾ ]  [ Keep Format ▾ ]  [ 📍 Next to file (-min) ▾ ]               │
│                                                       Saved 1.24 GB today   [ Clear Done ]   [ ⚙ ]       │
├──────────────────────────┬───────────────────────────────────────────────────────────────────────────────┤
│ ╭╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╮ │ ╭───────────────────────────────────────────────────────────────────────────╮ │
│ ╎                      ╎ │ │ [🎬]  product-demo-4k.mp4              [███████░░░░░]  58%        [ ✕ ]   │ │
│ ╎         ⬇ 📄         ╎ │ │       MP4 · Smart HEVC · 142 MB/s      412.0 MB → ~148 MB                 │ │
│ ╎                      ╎ │ ╰───────────────────────────────────────────────────────────────────────────╯ │
│ ╎  Drop files/folders  ╎ │ ╭───────────────────────────────────────────────────────────────────────────╮ │
│ ╎   Click · ⌘V paste   ╎ │ │ [🖼]  hero-banner@2x.png               14.8 MB → 5.3 MB   [ −64% ]        │ │
│ ╎                      ╎ │ │       PNG · Lossless · oxipng                        [🔍] [📋] [⇄] [✕]   │ │
│ ├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┤ │ ╰───────────────────────────────────────────────────────────────────────────╯ │
│ ╎ ⚡ 4 active · 198MB/s ╎ │ ╭───────────────────────────────────────────────────────────────────────────╮ │
│ ╎         [Cancel All] ╎ │ │ [🖼]  avatar-optimized.webp                   184 KB      [ Optimal ]     │ │
│ ╰╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯ │ │       WebP · Smart · Already optimal (no duplicate written)  [🔍] [📋] [✕] │ │
│                          │ ╰───────────────────────────────────────────────────────────────────────────╯ │
╰──────────────────────────┴───────────────────────────────────────────────────────────────────────────────╯
  ▲ 12 pt outer margin · 22 pt corner radius · slides over bottom Dock (screen.frame.minY + 12 pt)
  Action legend on hovered/selected card: [🔍] Reveal (↩)  [📋] Copy (⌘C)  [⇄] Replace Original (⌘R)  [✕] Remove/Cancel
```

### 8.3 Bottom Tray — Inline Settings Deck (`⌘,` Toggle, Zero Extra Window)

```text
╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│  ⚙ Settings                                                                          [ Done (Esc / ↩) ]  │
├───────────────────────────────────┬──────────────────────────────────┬───────────────────────────────────┤
│  PRESENCE & INPUT                 │  COMPRESSION ENGINE              │  OUTPUT & HYGIENE                 │
│  Hotkey:    [ ⌃⌥Space    ] [↺]    │  Smart Q:   [Compact|●Bal|Studio]│  Suffix:    [ {name}-min.{ext} ▾] │
│  Dropzone:  [ On file drag   ▾ ]  │  Strip EXIF:[✓ Smart] [ Lossless]│  Folders:   [ Mirror tree      ▾] │
│  Login:     [✓ Launch at login ]  │  Dates:     [✓ Keep timestamps  ]│  Keep List: [ 7 days           ▾] │
│  Feedback:  [✓ Haptics] [ Sound]  │  Threads:   [ Auto (P-Cores)  ▾ ]│  Dotfiles:  [✓ Skip] [Reset Stat] │
╰───────────────────────────────────┴──────────────────────────────────┴───────────────────────────────────╯
```

---

## 9. Display Name & App Icon Direction

**Display Name: *Logn*** (pronounced *"log-en"*, directly honoring the `o-log-n` repo name while reading as a crisp, single-syllable-feel Mac utility brand alongside *Raycast*, *CleanShot*, and *Dropover*). Logarithmic complexity—$O(\log n)$—is the purest metaphor for compression: turning massive inputs into compact footprints in minimal steps. **Icon Direction**: On a macOS 26 Liquid Glass squircle, render two sculpted, translucent obsidian-and-cobalt glass slabs gently pressing inward from left and right around a luminous emerald-tinted core prism, forming a subtle abstract `⟨·⟩` compression caliper. In Light Mode, frosted alabaster outer jaws refract warm specular highlights onto the jewel-like core; in Dark Mode and Clear/Tinted Tahoe icon appearances, deep smoked glass rims catch crisp top-lit caustic edges so the silhouette reads effortlessly at both `512 pt` in About/Settings and `16 pt` monochrome in the menu bar.
