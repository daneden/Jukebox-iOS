# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Playback** (Xcode target/scheme `Jukebox`, App Store listing "Playback Music", bundle ID `me.daneden.Jukebox`) is a single-target iOS 26 SwiftUI app that spins the user's Apple Music library on a 3D cover-flow-style dial. It's a personal app — one user, no telemetry, no server — so visual/experiential richness is fair game.

The product was originally named "Jukebox" — that name survives only as the Xcode target/scheme/folder name and the bundle ID suffix. Everything user-facing (home-screen icon, App Store listing, in-app copy) is "Playback".

Three tabs (default is **Songs**):
- **Songs** — "hidden gems" mode; builds a scored, similarity-walked deck of dormant songs (`GemDeckBuilder` + `GemScorer` + `SongDeckWalk`) and rides the dial. Walk filters (energy band, decade range, meander) refine the deck.
- **Playlists** — original surface; spins playlists and plays via `SystemMusicPlayer`. Also rides the dial.
- **Design** — *not* a dial. Hand-shape a five-point energy curve + song count; `DesignedPlaylistBuilder` orders songs along it. The result lands in History, where it can be saved to the Apple Music library.

Every generated run (Songs play, Design generate, and the `MakeAPlaylist` intent) is logged to `HistoryStore`; the **History** surface browses past runways and can materialize one into a real Apple Music playlist via `MusicPlayback.save`.

Siri/Shortcuts intents live in `Intents/` and all route through one shared core, `IntentActions`, so they don't drift from the app: `MakeAPlaylist` (parameterized by energy band/decade/count, defaulting to the saved walk filters), `DesignPlaylist` (a `CurvePreset` energy shape), `PlayRandomPlaylist`, and `SaveToLibrary` (materialize a generated playlist via `MusicPlayback.save`). The two generate intents return a `GeneratedPlaylistEntity` so Shortcuts can chain generate → save. `AppShortcuts.swift` wires the phrases.

**Control Center** controls live in the `WidgetsExtension` target (`Widgets/`): `PlayRandomPlaylistControl` + `MakeGemsControl`. Per Apple's controls model a control button's `perform()` runs in the **widget extension's** process (not the app, no foreground — the app is only launched for an `OpenIntent`). So the control intents (`Intents/ControlSupport.swift`, `supportedModes = .background`, `isDiscoverable = false`) are **self-contained**: MusicKit + Foundation only, no app-only builders. Play-random fetches a library playlist and hands it to `SystemMusicPlayer`; make-gems runs a deliberately-light pick (two bounded pools + a nostalgia score, no embeddings/walk/filters — those need the app). They run the Music work in the extension via `SystemMusicPlayer`, so the extension's Info.plist carries `NSAppleMusicUsageDescription`. **Gotchas:** (1) `ControlSupport.swift` must be a member of *both* the `Jukebox` and `WidgetsExtension` targets (manual Target Membership tick — synchronized groups default to one target). (2) Whether the extension inherits the app's MusicKit authorization is unverified on-device — if it doesn't, fall back to `OpenIntent` (which foregrounds).

## Build & run

Single target, single scheme — both named `Jukebox`. Swift 5, deployment target iOS 26.0.

```bash
# Build (device-agnostic destination; xcodebuild auto-picks a satisfying runtime)
xcodebuild -project Jukebox.xcodeproj -scheme Jukebox \
  -destination 'generic/platform=iOS Simulator' build

# Boot a named simulator only when you need it (screenshots, UI tests, simctl)
xcrun simctl boot 'iPhone 17 Pro'
```

There are no unit-test or UI-test targets. Verification is manual on a real device — see the `verify-ios` skill, and run `/verify-ios` after non-trivial changes and before `/ship`.

This project may trigger Xcode Cloud builds on push, so **do not push automatically** — batch commits and wait for the user to say "ship".

## Architecture

The dial is shared by Songs and Playlists modes; Design mode is a separate curve-editor surface. Behind Songs and Design sits a sizeable energy/embedding subsystem (audio fingerprints, BPM, centroid energy classification) that classifies and orders the library — see "Songs subsystem" below.

### The dial pipeline (`Jukebox/Dial/`)

`DialView<Item: MusicItem & DialItem>` is generic — both `Playlist` and `Song` conform to `DialItem` (just `var artwork: Artwork? { get }`). The dial knows nothing about playlists vs songs.

- `DialView.swift` — the rotating-cylinder view. Owns the drag/flick gesture, computes `continuousPosition` from `rotation`, snaps to detents, and renders a bounded window (`DialTunables.visibleHalf = 3` → 7 covers max regardless of collection size). Nested `DialContent` is `Animatable` over `rotation` so long-distance snaps actually fly through intermediate covers and fire the per-detent selection haptic from inside `animatableData`.
- `DialState.swift` — value-type bundle (`rotation`, `focusedIndex`, `focusedItemID`, `rippleCounters`, `spinLandTick`, `isSpinning`). Modes own one of these as `@State` and pass bindings into `DialView`. Plain value type — not Observable — so `withAnimation { dial.rotation = … }` works like a primitive.
- `DialMechanics.swift` — pure modular-arithmetic math: `spinDestination` (shortest path), `shuffleTarget` (bounded random jump), `reanchoredRotation` (preserve focus when the collection mutates). No SwiftUI.
- `DialTunables.swift` — single source for every visual + motion knob (step angle, scales, springs, flick-inertia curve, shuffle jump bound). Tune here; don't sprinkle constants.
- `DialItem.swift` — the `DialItem` protocol; `Playlist` and `Song` extensions live here.
- `CoverArtView.swift` — generic artwork tile; takes a `requestedWidth` smaller than display `width` so the dial can request artwork at the **focused-scale** peak size and upsample non-focused covers without paying for full-size pixels everywhere.

### Modes (`Jukebox/Modes/`)

Each mode is a `View` that owns: how items are fetched, sort/build preferences, and how playback is started. Everything else (focus tracking, ripple counters, spin land animation, haptics) goes through `DialState`.

- `Playlists/PlaylistsView.swift` — `MusicLibraryRequest<Playlist>` sorted by `lastPlayedDate` descending, streams successive batches into `applyPlaylists`, reanchors focus on the same playlist across updates. Intentionally does **not** refetch on play (see "Watch out for" below).
- `Songs/SongsView.swift` — builds the deck via `GemDeckBuilder.buildStreaming(controls:)` (passing the persisted `WalkControls`), seeds `SystemMusicPlayer.shared.queue` with a 20-song runway from the focused song forward, and records each play to `HistoryStore`. Shuffle is a full rebuild (`wideSample`), not a re-walk. Per-cover context menu flags songs/albums/artists into `ExclusionStore`. Walk filters live in the `WalkControls*` files and persist via `SettingsKeys.walk*`.
- `Design/DesignView.swift` + `Design/DesignedPlaylistBuilder.swift` — five-point `EnergyCurve` (+ `EnergyCurveEditor`) and a song count; the builder fetches a broad unfiltered pool (two base pools + one genre slice per band), classifies every song's energy, then walks the curve picking the nearest-energy unused song per evenly-spaced sample. Fresh fetch, not the Songs deck — Design wants curve-dictated transitions, the opposite of the similarity walk. Records to `HistoryStore` and opens the result in `HistoryDetailView`.

### Songs subsystem (`Jukebox/Modes/Songs/`, `Jukebox/Persistence/`)

The scoring/ordering pipeline behind Songs mode (and reused by Design for energy):

- `GemDeckBuilder.swift` — fetches **three** parallel pools (nostalgia: top `playCount`; discovery: oldest `libraryAddedDate`; freshness: newest `libraryAddedDate`; `basePoolSize` 1000, scaled up when walk filters narrow), plus an optional per-band genre slice. Dedupes, drops `ExclusionStore` items, scores with `GemScorer`, applies energy/decade filters and per-artist/album caps, keeps top 300, then `SongDeckWalk` orders them. Gates fan-out behind `MusicKitWarmup.waitUntilReady()` (cold-launch `musicd` race). Fire-and-forget warms embeddings for the deck afterward.
- `GemScorer.swift` — pure function, three tracks: **Nostalgia** `playCount × dormantMonths` (log-saturated), **Discovery** `libraryAgeMonths / (plays+1)`, **Freshness** for recently-added-but-drifted songs. Recency is a soft multiplier (not a hard 14-day exclude); unplayable songs (nil `playParameters`) are hard-excluded.
- `SongDeckWalk.swift` — greedy similarity walk: cosine over cached audio embeddings, genre-similarity fallback for un-embedded songs. Hard diversity rules (no same artist within 2, same album within 3) with graceful relaxation.
- `AudioEmbeddingService.swift` / `EmbeddingStore` / `LibraryEmbeddingWarmer.swift` — feed a song's 30s preview through `AudioFeaturePrint`, mean-pool to one fingerprint, cache in SwiftData. The warmer embeds the long tail (WiFi always required; background passes require power, foreground defers to Low Power Mode).
- `EnergyClassifier.swift` / `EnergyCentroids*` / `SongEnergy.swift` / `BPMDetector.swift` — centroid-based energy band (glacial/mellow/energetic/intense) with a self-calibrating per-band threshold; BPM floats the band center into a continuous energy value. Genres come from `GenreStore`, never `Song.genreNames` (always empty on library songs).
- `Persistence/` — SwiftData stores: `HistoryStore` (logged runways, local-only, no CloudKit), `EmbeddingStore`, `GenreStore`, `ExclusionStore`, `OriginalReleaseStore` (remaster→original date for decade filtering), `TransitionFeedbackStore` (blocked walk pairs), `LibraryStatsStore`.

### History (`Jukebox/History/`)

- `HistoryView.swift` / `HistoryDetailView` — browse past runways; `PlaylistNamer` suggests mood-leaning names; "Save to library" calls `MusicPlayback.save` to materialize a real Apple Music playlist; `ShareLink` shares a rendered cover. This save path is the one Siri/Shortcuts does **not** yet reach.

### Shared (`Jukebox/Shared/`, `Jukebox/Effects/`, `Jukebox/Helper Views/`)

- `MusicPlayback.swift` — cross-platform playback/save verb. iOS uses `SystemMusicPlayer` + `MusicLibrary.createPlaylist`; macOS routes through `AppleMusicScriptBridge` (AppleScript). `play(playlist:)`, `play(songs:)`, `save(songs:asPlaylistNamed:description:)`.
- `PlaybackControls.swift` — Play + Shuffle pair, glass effect container. The dial modes embed it via `.safeAreaBar(edge: .bottom)`.
- `LibraryStateOverlay.swift` — single overlay for unauthorized / loading / empty / error states; modes pass their own copy.
- `SettingsMenu.swift` — top-leading menu (the autoplay toggle). Also the home of the `SettingsKeys` enum, which now keys autoplay, the Songs walk filters (`walk*`), and Design prefs (`design*`) — far more than the menu surfaces.
- `ToolbarLogo.swift` — principal toolbar item shown in every tab.
- `Effects/Ripple.metal` + `RippleModifier.swift` — Metal shader ripple. The dial applies `RippleEffect` to each cover and bumps a per-item trigger counter in `DialState.rippleCounters` so a shuffle landing only ripples the landed cover.
- `Helper Views/AsyncButton.swift` — Button wrapper that shows a `ProgressView` while its async action runs. Used by `PlaybackControls`.

## Watch out for

These traps are documented in memory (`memory/MEMORY.md`); brief versions:

- **Don't refetch the playlist list mid-shuffle.** Sorting by `lastPlayedDate` reorders the just-played playlist to index 0; `reanchor` then mutates rotation without animation → visible "jerk at settle". `PlaylistsView` deliberately omits `.onChange(of: chosenPlaylist) { update() }`. If a future change wants in-session reorder, animate the rotation mutation inside `reanchor` (`withAnimation(.smooth(duration: 0.5))`).
- **Bounded rendering, always.** The user tests on a real iPhone and watches Xcode's memory/energy gauges. Anything that renders artwork (or other media-backed views) must use a fixed-size sliding window — `DialTunables.visibleHalf` controls this for the dial. Don't render N covers because the data has N items.
- **Framework-first.** Before hand-rolling motion/date/style code, check the SwiftUI/MusicKit API surface — past mistakes include rolling manual date math instead of `Text(date, style: .relative)` and concatenating `.fill` suffixes instead of `.symbolVariant(.fill)`. The dial already uses `TimelineView`, `Animatable`, `sensoryFeedback`, `keyframeAnimator`; prefer those over `Timer` / `withAnimation` math.

## Conventions

- Comments explain **why** (a non-obvious constraint, a past incident), not **what**. Don't reference the current task/PR — that rots.
- No backwards-compatibility shims when a clean change is possible; this is a single-user app with no API surface.
- Persistent user prefs live in `@AppStorage` keyed off `SettingsKeys` (in `SettingsMenu.swift`).
