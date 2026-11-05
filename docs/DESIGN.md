# OwlLuna design notes

The look is Clothbound: the library is a shelf of cloth-bound notebooks, and the editor a quiet, warm desk round the page. Print is a second cover style, taken from riso printing. Of the other directions we tried, only Drafting Table's tabular numerals stayed.

## Principles

- The canvas stays quiet. Paper and ink only, and nothing moves while you write.
- Controls are bound like the notebooks: plates ruled onto bars, boards standing on the desk, wells pressed into it, and cloth for the action that finishes a task. No Liquid Glass and no blur of our own.
- We draw our own menus, alerts, lists, switches, progress and empty states. Only the library sidebar (a `List`, for its selection and drag and drop) and the share sheet are system.
- Cut square. Controls use the corner scale below, never capsules.
- Each control lives in one place. The exceptions: the tool tray's shortcuts are also in the Add and More menus, and a text box's Bold, Italic and Underline are on its Text Style card and in the arrange bar where it has room.
- Colour never carries meaning alone. Favourites get a ribbon and a spoken label, selection gets stitching and a check mark, and a wash that marks something has an edge too.
- Printed matter keeps its colours at night: covers, labels, tags, stickers, index cards, the splash tiles.

## Colour tokens

Tokens live in `OwlLuna/Assets.xcassets` with light, dark and Increase Contrast variants. Use the asset symbols (`Color.paper`, `UIColor.ink`).

| Token | Light | Dark | Use |
|---|---|---|---|
| Paper | `#F1EDE4` | `#181613` | Library and Settings ground |
| Desk | `#E7E2D7` | `#121110` | Round the page in the editor |
| Surface | `#F8F6F1` | `#211F1B` | Sidebar, sheets, menus, Settings cards |
| Ink | `#1B2230` | `#ECE6DA` | Text |
| TextSecondary | `#404656` | `#BDB6A9` | Secondary text, placeholders, `.metaStyle()`. Holds 7:1 |
| InkSecondary | `#5A6070` | `#A8A194` | Thumb and knob edges with Increase Contrast |
| AccentColor | `#2747B8` | `#8FA8FF` | Cobalt ink: tint, links, focus, the tool in hand |
| SidebarTint | `#2747B8` | `#4466DD` | Sidebar icons on Surface (3:1) |
| Tomato | `#C9452F` | `#FF7B61` | Favourite ribbon, recording, destructive icons |
| OnTomato | `#FFFFFF` | `#181613` | Text on Tomato. White fails on dark tomato (2.5:1) |
| Mustard | `#E8B023` | `#F0BE45` | Highlights, stitched selection, chosen tags |
| OnMustard | `#1B2230` | `#1B2230` | Text on Mustard |
| LabelCream | `#F7F1E3` | `#E9E1CE` | Cover labels and tags, light at night too |
| LabelInk, LabelInkSecondary | `#1B2230`, `#5A6070` | `#1B2230`, `#505665` | Text on labels |
| Hairline | Ink at 15% | Ink at 15% | Rules and edges. 32% with Increase Contrast |
| Board | `#FAF7F0` | `#2A2722` | Raised panels, tab thumbs. Lighter than a dark sheet, so it lifts at night |
| Well | `#5A4526` at 9% | Black at 38% | Fields and tracks. 14% and 55% with Increase Contrast |
| PrimaryCloth, OnPrimaryCloth | `#2747B8`, `#F1EDE4` | `#3A5BB8`, `#ECE6DA` | The finishing button. Deeper than the tint at night |
| DestructiveCloth, OnDestructiveCloth | `#C9452F`, `#FFFFFF` | `#A83E2B`, `#ECE6DA` | Stop recording, confirm a deletion |

`DesignTokenTests.testEveryTextPairReachesAA` checks every text pair in all four appearances. The lowest:

| Pair | Light | Light + IC | Dark | Dark + IC |
|---|---|---|---|---|
| InkSecondary on Desk | 4.86 | 6.62 | 7.36 | 10.97 |
| OnTomato on Tomato | 4.80 | 6.52 | 7.10 | 9.06 |
| LabelInkSecondary on LabelCream | 5.58 | 8.29 | 5.64 | 8.27 |
| Accent on Desk | 6.07 | 7.72 | 8.27 | 10.59 |
| TextSecondary on Desk | 7.30 | 9.19 | 9.37 | 12.40 |

Cloth colours (`ClothColor`): Oxblood `#6E2A2A`, Tomato `#C9452F`, Mustard `#D6A02A`, Moss `#3D5A40`, Jade `#2F7D6B`, Cobalt `#2F4DA0`, Navy `#1E2A45`, Plum `#5A2F52`, Slate `#56606B`, Rose `#C98A86`, Oat `#CDBF9F`. They are cover and spine content, never text grounds, so they live in code. Ribbon text uses `onCloth`.

Riso inks (`RisoInk`): pink `#FF48B0`, yellow `#FFE800`, teal `#00838A`, blue `#0078BF`, black `#1C1C21`, on paper stock `#F7F4EC`. Only on Print covers and the Print icon, never on controls.

## Type

- Fraunces (SIL OFL): library headings, empty states, cover labels, and text boxes set in it. Use `.displayFont(_:relativeTo:)` for headings and `.displayTextFont(_:relativeTo:)` for running text: `Font.custom` on `Fraunces-SemiBold` and `Fraunces-Regular`, so they scale with Dynamic Type, one weight heavier with Bold Text. Cover labels (`OwlLunaFonts.coverLabel`) are SOFT 50, WONK 1; typed text (`OwlLunaFonts.text`) is SOFT 0, WONK 0. Only the upright is bundled, so italic is a slant.
- Bricolage Grotesque (SIL OFL): Print cover titles only, condensed ExtraBold (wdth 75, wght 800) through the axes (`OwlLunaFonts.printTitle`), since there's no named condensed instance.
- Archivo (SIL OFL): the launch splash only. Black (wght 900) at wdth 62 for the wordmark, volume number and stamp, wdth 95 for the ticker (`OwlLunaFonts.splashTitle`). Drawn as outlines (`SplashType`), so a line can be scaled to its tile and each letter moved alone.
- SF Pro: all other UI. Metadata uses `.metaStyle()`: small caps, tracking, tabular digits.

The fonts are bundled unmodified from google/fonts in `OwlLuna/Resources/Fonts`, beside their `OFL-*.txt`, and Settings › Acknowledgements shows each. `OwlLunaFonts.register()` registers them at launch with `CTFontManagerRegisterFontURLs`, because Xcode writes the Info.plist from build settings. No licence declares a Reserved Font Name, and we neither instance nor rename the fonts. Widgets don't bundle them and use the system serif.

## Spacing, shape, motion

- Spacing: a 4 pt grid, `Space.x1` (4) to `Space.x12` (48).
- Corners (`Radius`, and the shapes `RoundedRectangle.plate`, `.thumb`, `.track`, `.bar`): `plate` 4 for buttons, chips, fields, cards, menus and notices; `thumb` 3 for what slides inside something; `track` 6 for the well it slides in; `bar` 8 for boards floating over a page; `sheet` 12, which every `.sheet` gets through `.presentationCornerRadius(Radius.sheet)`. No other radii for controls.
- Covers: 3:4. Spine corners 1.3% of the width and fore-edge corners 3.5% in the renderer; `Radius.coverSpine` and `Radius.coverEdge` in SwiftUI.
- Motion: `Motion.standard` (0.18 s ease-out), `Motion.quick` (0.15 s), and a spring for the favourite ribbon and the ink dish (`Motion.ribbon`). Opening a notebook zooms out of what was touched: a cover, the open spread, a search result. With Reduce Motion, `Motion.adaptive` makes all of it a short cross-fade.

## Materials

In `Design/Surfaces.swift`. Boards never sit inside scrolling grids or lists, where their shadows would be drawn live.

- Plate (`.plate(in:fill:)`): flat, ruled in ink at 35% (70% with Increase Contrast), no shadow. Bars, menus, notices and ledgers are cut from it.
- Board (`.board(in:)`): Board fill, a Hairline edge, a lit top edge and an umber shadow (`Elevation.shade`, black at night). For what stands clear of the ground: floating bars, tab thumbs, buttons outside bars. Pressed, it sinks into a well; disabled, it is an edgeless slab at half strength.
- Well (`.well(in:focused:)`): an inner shadow and a lit lower lip, for fields and tracks. A 1.5 pt accent ring while focused.
- Cloth: PrimaryCloth or DestructiveCloth with the covers' weave (`ClothWeave`) and a bevel. Increase Contrast drops the weave, the bevel and the board's lit edge.

## Controls

- Buttons: `.owlLuna` is Ink on a board, or on a plate in a bar (`inBar: true`). `.owlLuna(.primary)` is cobalt cloth, for the one action that finishes a task: Done, Create, Save, Share. `.owlLuna(.destructive)` is tomato cloth, for stopping a recording and confirming a deletion. Anything else that deletes is a tomato icon or an Ink word, and asks first or can be undone.
- Bar icons: `.barIcon` is a 44 pt Ink icon that presses into a small well. `BarGroup` rules a run of them onto one plate. `.plateIcon` is one icon on its own plate, and `.plateIcon(lifted: true)` stands it on a board over a page.
- Bars: `.boardBackground()` drops the system glass from a toolbar item, and `.barGround(_:)` keeps a bar its ground colour under scrolling content. Bar controls stop growing at the largest standard text size and show the Large Content Viewer. A field or tabs that don't fit take a row under the bar, never the overflow menu.
- Fields: `OwlLunaSearchField` in bars (Escape clears it, then leaves it); `.owlLunaField(focused:)`, a well, in sheets.
- Tabs: `OwlLunaSegmentedPicker`, equal segments on a track with a board thumb that slides. The chosen label is Ink semibold, the rest TextSecondary.
- Switches: `.toggleStyle(.owlLuna)`, the Slab. A 54 by 30 pt track and a square knob; on, the track is woven PrimaryCloth. VoiceOver and tests see an ordinary switch.
- Selection: `StitchedSelection`, a mustard dashed outline with a check, on covers and thumbnails. On the page, mustard dashes over an ink line, so it shows on any paper.
- Tags: `TagChip`, a LabelCream paper label with a punched hole (`TagHole`), Mustard with a check when chosen, a dashed edge when only some notebooks carry it.

## Named components

Each was picked from a set of mocks and replaces the system piece.

- Bookplate bar: the library bar, and the model for the rest. Ink-ruled plates with worded actions (Sort, Select) and one cloth button for the main action (New: tap to create, and a chevron cut off its end, or its foot in a vertical bar, that opens the menu; holding does too).
- Card menus (`Design/Menus.swift`, presented by `Design/PanelPresenter.swift`): every menu and popover. A Surface plate under a woven cloth band that names it, rows ruled like an index card. Use `OwlLunaMenu`, `OwlLunaPicker(_:selection:)`, `MenuBreak()`, `.menuChosen(_:)` and `.panel(_:isPresented:)` (`adapts: true` becomes a sheet when narrow). Long-press menus use `.heldMenu(_:when:draggable:)`, with `draggable: true` where the view can also be dragged.
- Stamp alerts (`.notice` in `Design/Notices.swift`): every alert and confirmation. A plate with a cloth edge down its leading side (tomato when something is destroyed), a flat Cancel and one cloth button. Write Cancel first and the main button last. A cancel-role button is its only way out.
- Ledger lists (`Ledger`, `.ledgerSwipe` in `Design/Ledger.swift`): lists in sheets. One ink-ruled plate per run of rows under a well band; a swipe uncovers cloth blocks.
- Thread progress (`ThreadProgressStyle`): every `ProgressView` wears `.thread`, set at the app root. A thin well with a cobalt thread.
- Bookplate empty states (`EmptyPlate`): an empty sheet or list. A plate with the symbol in a small square, a Fraunces title, one line. The library's own empty states are drawings (`ShelfIllustration`, `RibbonIllustration`).
- Mixing strips (`InkMixer` in `Editor/PenOptions.swift`): a pen's custom colour, as a hue strip and a shade strip with square knobs beside a blot of the ink.
- Cloth sidebar row (`RowCloth`, `scoped(_:chosen:)` in `Library/LibrarySidebar.swift`): the chosen shelf on a woven PrimaryCloth plate. `CellFocusRing` removes UIKit's focus ring there.
- Bar-plate sync notice (`SyncNoticeButton` in `Library/SyncNotice.swift`): failures and conflicted copies, as a worded "iCloud" plate in the library bar with a count square (tomato for trouble) that opens a Card.
- Bar-thread sync progress (`SyncThread`, `UploadMark`, `SyncTicks`, same file): a 3 pt cobalt thread along the foot of the library bar once a pass has run 0.3 s, "Not uploaded yet" in words under a cover, and square ticks in Settings.
- Catalogue list (`NotebookCatalogueRow`, `ShelfListSort` in `Library/ShelfList.swift`): the library's List layout. Rows on the paper, a 44 pt cover, a Fraunces title, folder and tag labels, sort tabs over the rows.
- Large-text ledger (`NotebookLedgerRow`, `ShelfView.ledger(_:)`): Shelf at accessibility text sizes. A board per run, covers growing with the text up to 64 pt.
- Proof-strip export options (`ExportChoices`, `ProofStrip`, `PlatePair` in `Services/ExportChoices.swift`): page thumbnails with mustard ends dragged to choose the range, a pair of plates per either-or choice, a Slab for searchable handwriting, and a cloth "Export 9 Pages".
- Settings parts (`Settings/SettingsParts.swift`): no `Form`. Each `SettingsSection` is a Fraunces heading over one ruled Surface plate with a note beneath. Choices (`SettingsChoiceRow`) show their value on a small square well.

## Covers

`CoverRenderer` draws each cover once per request, off the main thread, into an 80 MB LRU and `Caches/Covers` on disk. A render or disk read fades in (0.15 s); a memory hit appears at once. Nothing is blended or shadowed live in a scrolling grid. The ribbon (`FavoriteRibbon`) and selection are SwiftUI overlays, so they can animate.

From 100 pt wide, a cover is a closed notebook: cream leaves past the board, a 1 px bevel, and a shadow baked into a 9-slice plate (`CoverShadowPlate`).

- Cloth: weave, rounded spine, hinge groove and a cream label with a double hairline, a Fraunces title and a small-caps meta line (shelf name or start month). Never the page count, which sits under the cover so a new page doesn't re-render it.
- Print: two riso inks overprinted on paper stock, saddle-stitched. Patterns come from `CoverRNG(id:seed:)`, misregistered by up to 0.3 pt. The uppercase Bricolage title sits on a paper-stock knockout, so the pattern never touches its contrast.
- First page: the page thumbnail behind a narrow cloth spine. Imported PDFs default to it.

At night the cover boards dim about 10% and labels stay light; paper and ink never invert. Increase Contrast drops the weave and shaded spine, adds a 1 pt Hairline outline, and gives Print two solid blocks.

## Library and editor

- Continue writing (`OpenBookSpread`) leads the library: the last notebook lying open. Below it, `ShelfMetrics.fit` picks columns for about 176 pt a cover (136 to 232), so there's never a gutter, and each row stands on a `ShelfLedge`.
- Search matches are bold on a highlighter band: mustard at night, ochre `#806113` under LabelCream by day, because Apple's audit reads a pale band as faint text.
- The tool tray (`ToolTray`) is one 48 pt board at the foot of the editor, over the desk, so it takes nothing from the page. Pens are labels with the ink as a blot: paper by day, wells at night with a lighter rim round the blot. The pen roll (`PenRoll`) and the ink dish (`InkDish`) draw ink the same way.
- Floating bars (arrange, link back, presenter, replay) are boards with `Radius.bar` corners and a compact cloth Done. They grow with the text.
- Washes always have an edge: selected text (accent), find matches and the transcript's current line (mustard). The current find match also gets an Ink outline.
- Stickers (`Sticker`) are pastel paper with a deeper edge and a shadow of layered tints, not blurs, so they stay vector in a PDF. Study tape (`TapeArt`) is opaque washi; lifted, it leaves a dashed outline.
- Flashcards are cream index cards (`CardPaper`). In study, Show Answer and Good are cloth; Again and Easy are boards.
- Widgets use Paper and Ink, the system serif and small caps. This Week never frames a run of days as a streak to keep.

## App icon

A brown owl in round glasses on a crescent moon, with a pad and a pencil. `Shared/OwlLunaArt.swift` draws it without UIKit or AppKit, as layers in draw order (`OwlLunaLayer`), so the icons, the Settings previews and the About mark share one source.

- Six skies in Settings › App Icon: Cobalt (the primary, violet `#4F2DD3` to `#3E20B5`), Tomato, Moss, Oxblood, Mustard and Print. The alternates are in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, checked by `AppIconTests`. The picker uses `IconPreview-*` tiles.
- Light has the sky and a glow kept 80 px inside the edge, and no alpha. Dark is the same art on transparent. Tinted is greyscale with the moon dropped to mid-grey, so the owl stands off it.
- To redraw: `swiftc -O Scripts/AppIcon/*.swift Shared/OwlLunaArt.swift -o .build/make-icon && .build/make-icon OwlLuna/Assets.xcassets docs`. It rewrites every icon set, the previews and `docs/icon-sheet.png`. The output is deterministic and committed.
- `OwlLunaMark` (`Design/OwlLunaMark.swift`) is the icon as a SwiftUI tile for Settings › About, built from `OwlLunaArt.parts` (`OwlLunaMarkGroups`). Violet by day, midnight navy-violet (`#1E1449` to `#140D33`) at night.

## Launch

`BentoSplash` (`Launch/BentoSplash.swift`) fills the window with seven flat, ink-outlined tiles on Paper, on a twelve-column grid under the status bar:

- the owl on its perch with a pad and pencil, on moon yellow `#F4DE3C`
- a ruled note page, on Board
- a crescent moon, on ink
- three index cards under a STUDY stamp, on yellow
- VOL. 01, on Board
- a ticker of WRITE, SKETCH and STUDY, on Tomato
- the wordmark on an ink slab, OWL in paper and LUNA in yellow.

A landscape window has twelve rows, a portrait one fourteen with the owl across the top, and one twice as wide as tall stands the owl down its left side. At night only the Paper under the tiles and their outline (cream) change.

The labels, ticker and stamp words are localised capitals (`BentoWords`); the wordmark and 01 are not. A word with a letter Archivo lacks falls back to its English, and a long stamp word is set smaller rather than squeezed past a quarter. The checklist is hand-printed by `NoteHand` (`Launch/BentoNoteTile.swift`), A to Z with the common accents, each letter leaning nine degrees.

### Choreography

Every value is a pure function of one millisecond clock (`SplashClock`, `SplashBeat`, `SplashTrack` in `Launch/SplashTimeline.swift`). Each tile draws itself in a `Canvas`, only when its own moment changes. SwiftUI animates nothing.

- From 30 ms the tiles spring in from their nearest edges, 55 to 60 ms apart, tilted, overshooting and locking (0.9 s, damping 0.56 to 0.64). VOL. 01 is stuck on last, at 0.56 s.
- The owl: the perch draws and the pale disc pops (0.33 s), it hops up (0.47 s), swings its pencil down (0.8 s), writes a line (1.04 to 1.56 s), then looks up and tilts its head.
- The wordmark's letters rise out of a clipped line 55 ms apart from 0.59 s, over a rule growing from the left. The digits of 01 rise the same way.
- The page rules itself, the checklist is printed, two words are ticked in red, a star and moon phases are drawn and the third word highlighted (0.84 to 1.7 s).
- The moon rises and rocks, its stars pop, the cards fan up and the stamp lands (1.34 s).
- By 1.7 s the scenes have played, except the owl's head, which settles by 2.16 s. Then only loops run: ticker, moon, twinkling stars, the stamp's wobble, a blink every 2.6 s.

### Hand-over

From 2.15 s, once the library is ready, each tile gets a paper plate under it, the library appears beneath at 1.05 scale and settles over 0.5 s, and the tiles peel off 26 ms apart, wordmark first and moon last, each to its nearest edge (0.27 to 0.32 s). If the library isn't ready, the splash holds with its loops running.

`LaunchOverlay` (`App/LaunchOverlay.swift`) moves the clock on by at most 50 ms a frame, so a busy main thread holds the splash rather than skipping it. It takes no touches and is one VoiceOver image, "OwlLuna"; the library stays hidden from VoiceOver until the hand-over.

Nothing is shown from under the splash (`LaunchCurtain`). A link or shortcut that arrives mid-splash sends the tiles off once the library is ready, and runs when the last has gone. Tiles sent off early leave from where they are, ones not yet in never come, and in the first 60 ms the splash just ends.

With Reduce Motion the splash is a still of its finished scene. It fades in over 0.25 s, holds until the library is ready (and for 1.45 s, unless something is waiting), and fades out over 0.35 s as the library fades in.

`LaunchAnimation.isEnabled` allows the first scene of the process only: never under tests, and not with `-storageRoot` or `-skipLaunchAnimation`. A launch that is about to show something (a notebook left open, a link, a search result, a shortcut) skips the splash too. In Debug, `-splashFreeze <ms>` holds the splash at one moment, for screenshots.
