# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Playback** (Xcode target/scheme `Jukebox`, App Store listing "Playback Music", bundle ID `me.daneden.Jukebox`) is a single-target iOS 26 SwiftUI app that spins the user's Apple Music library on a 3D cover-flow-style dial. It's a personal app — one user, no telemetry, no server — so visual/experiential richness is fair game.

The product was originally named "Jukebox" — that name survives only as the Xcode target/scheme/folder name and the bundle ID suffix. Everything user-facing (home-screen icon, App Store listing, in-app copy) is "Playback".

Two tabs share the same dial component:
- **Playlists** — original surface; spins playlists and plays via `SystemMusicPlayer`.
- **Songs** — "hidden gems" mode; builds a scored deck of dormant songs (`GemDeckBuilder` + `GemScorer`) and rides the same dial.

There's also an App Intent (`Intents/PlayRandomPlaylist.swift`) for Siri/Shortcuts.

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

The dial is the whole app. The interesting design is how Playlists mode and Songs mode share it.

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
- `Songs/SongsView.swift` — calls `GemDeckBuilder.build()` once per session, seeds `SystemMusicPlayer.shared.queue` with a 20-song runway from the focused song forward so playback keeps flowing.
- `Songs/GemDeckBuilder.swift` — fetches two parallel pools (top-`playCount` and oldest `libraryAddedDate`, 1500 each), dedupes, scores with `GemScorer`, takes top 300, then shuffles within top-N for per-session variety. Two pools instead of full-library scan is deliberate — a heavy user can have 50k songs.
- `Songs/GemScorer.swift` — pure function. Nostalgia = `log(plays+1) × dormantMonths`; Discovery = `libraryAgeMonths / (plays+1)`. Songs played in the last 14 days are filtered out entirely. Default blend: 70% nostalgia, 30% discovery.

### Shared (`Jukebox/Shared/`, `Jukebox/Effects/`, `Jukebox/Helper Views/`)

- `PlaybackControls.swift` — Play + Shuffle pair, glass effect container. Both modes embed it via `.safeAreaBar(edge: .bottom)`.
- `LibraryStateOverlay.swift` — single overlay for unauthorized / loading / empty / error states; modes pass their own copy.
- `SettingsMenu.swift` — top-leading menu; currently just the `@AppStorage("autoplay")` toggle. Both tabs read the same key so the setting stays in sync.
- `ToolbarLogo.swift` — principal toolbar item shown in both tabs.
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
