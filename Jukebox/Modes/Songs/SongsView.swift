//
//  SongsView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Songs (hidden-gems) mode. Builds a curated deck of songs from the user's
/// library (formerly-played-now-dormant + old-and-untouched) and rides the
/// same dial as Playlists mode. On play, seeds the system queue with a 20-
/// song runway so playback keeps flowing when the user puts the phone down.
struct SongsView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true
	@AppStorage(SettingsKeys.walkMeander) private var meander: Double = WalkControls.default.meander
	@AppStorage(SettingsKeys.walkEnergy) private var energyRaw: Int = WalkControls.default.energy.rawValue
	@AppStorage(SettingsKeys.walkDecadeLower) private var decadeLower: Int = WalkControls.default.decadeRange.lower
	@AppStorage(SettingsKeys.walkDecadeUpper) private var decadeUpper: Int = WalkControls.default.decadeRange.upper

	@State private var deck: MusicItemCollection<Song> = []
	@State private var dial = DialState()

	@State private var isLoading: Bool = true
	@State private var loadError: String?
	@State private var hasBuiltDeck = false
	@State private var showingHistory = false
	@State private var showingWalkControls = false
	/// Captured at popover-open time so we can tell on dismiss whether
	/// the user actually changed anything and skip the rebuild if not.
	@State private var walkControlsAtOpen: WalkControls?
	/// True while a shuffle-driven rebuild is in flight. The dial is
	/// pulled offscreen for the duration so the deck swap doesn't
	/// visibly thrash; a loading view sits in its place.
	@State private var isReshuffling = false
	/// Previous shuffle's seed neighbourhood. Passed back into the
	/// next shuffle so the walk's seed picker actively jumps away —
	/// without this hint the top-tier of a heavily-oldies library
	/// tends to land on the same decade/artist cluster repeatedly.
	@State private var lastShuffleDecade: Int?
	@State private var lastShuffleArtist: String?
	/// Min/max release decades observed in the unfiltered candidate
	/// pool — surfaced from GemDeckBuilder's BuildResult so the
	/// walk-controls range slider can constrain its thumbs to
	/// decades that actually exist in the user's library.
	@State private var libraryDecadeBounds: ClosedRange<Int>?
	/// `OriginalReleaseStore` snapshot from the latest build, kept on
	/// the view so the shuffle-avoid hint can read a focused song's
	/// original decade without another actor hop.
	@State private var lastBuildOriginals: [MusicItemID: Date] = [:]

	private var walkControls: WalkControls {
		WalkControls(
			meander: meander,
			energy: EnergyBand(rawValue: energyRaw) ?? .any,
			decadeRange: DecadeRange(lower: decadeLower, upper: decadeUpper)
		)
	}

	private var walkControlsBinding: Binding<WalkControls> {
		Binding(
			get: { walkControls },
			set: { new in
				meander = new.meander
				energyRaw = new.energy.rawValue
				decadeLower = new.decadeRange.lower
				decadeUpper = new.decadeRange.upper
			}
		)
	}

	private var focusedSong: Song? {
		guard !deck.isEmpty,
		      dial.focusedIndex >= 0,
		      dial.focusedIndex < deck.count else { return nil }
		return deck[dial.focusedIndex]
	}

	/// `focusedSong` only while the dial is at rest. Used by the title block
	/// so the text empties out during shuffle / reshuffle instead of
	/// disappearing, which would shift the dial up and back.
	private var settledSong: Song? {
		(dial.isSpinning || isReshuffling) ? nil : focusedSong
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				#if os(macOS)
					ToolbarLogo()
						.padding(.top, 8)
				#endif

				Spacer(minLength: 0)

				WalkFilterChips(controls: walkControls) {
					walkControlsBinding.wrappedValue = .default
					Task { await rebuildForWalkControlsChange() }
				}

				ZStack {
					if isReshuffling {
						reshuffleLoadingView
							.transition(.blurReplace)
					} else {
						DialView(
							items: deck,
							rotation: $dial.rotation,
							focusedIndex: $dial.focusedIndex,
							rippleCounters: dial.rippleCounters,
							placeholderSymbol: "music.note",
							contextMenu: { song in songContextMenu(for: song) }
						) {
							if let song = focusedSong {
								Task { await play(from: song) }
							}
						}
						.allowsHitTesting(!dial.isSpinning)
						.transition(.blurReplace)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.animation(.smooth(duration: 0.45), value: isReshuffling)

				TitleBlock(
					title: settledSong?.title ?? "",
					subtitle: settledSong?.artistName ?? "",
					onTap: { if let song = settledSong { open(song) } }
				)
				// Scoped to the title block subtree on purpose — applying
				// this on the parent VStack also catches `DialContent`'s
				// `animatableData: rotation`, so the first deck load (which
				// changes `focusedSong?.id` from nil → some id at the same
				// time as `dial.rotation` jumps to a non-zero landing
				// position) visibly spins the dial on cold launch.
				.animation(.easeInOut(duration: 0.25), value: settledSong?.id)

				Spacer(minLength: 0)
			}
			.task(id: scenePhase) {
				if scenePhase == .active, !hasBuiltDeck { await buildDeck() }
			}
			.refreshable { await buildDeck() }
			.safeAreaBar(edge: .bottom, alignment: .trailing) {
				PlaybackControls(
					disabled: dial.isSpinning || deck.isEmpty || isReshuffling,
					onPlay: { if let s = focusedSong { await play(from: s) } },
					onShuffle: { await shuffle() }
				) {
					Button {
						walkControlsAtOpen = walkControls
						showingWalkControls = true
					} label: {
						Label("Filters", systemImage: "slider.vertical.3")
							.imageScale(.large)
							.labelStyle(.iconOnly)
					}
					.buttonStyle(.glass)
					.buttonBorderShape(.circle)
					.controlSize(.extraLarge)
					.disabled(dial.isSpinning || isReshuffling)
					.popover(isPresented: $showingWalkControls) {
						WalkControlsPopover(
							controls: walkControlsBinding,
							libraryDecadeBounds: libraryDecadeBounds,
							poolSize: hasBuiltDeck ? deck.count : nil
						)
						// Floating popover stays on regular size
						// classes (iPad, macOS); compact (iPhone)
						// adapts to a sheet — the popover frame
						// was too cramped on phone-sized screens.
						.presentationCompactAdaptation(.sheet)
						.presentationDetents([.medium, .large])
						.presentationDragIndicator(.visible)
					}
				}
			}
			.onChange(of: showingWalkControls) { wasShowing, nowShowing in
				// Rebuild on dismiss rather than per-slider-step so the
				// user can scrub freely without thrashing the deck.
				if wasShowing, !nowShowing,
				   let snap = walkControlsAtOpen, snap != walkControls
				{
					walkControlsAtOpen = nil
					Task { await rebuildForWalkControlsChange() }
				}
			}
			.toolbar {
				ToolbarItem(placement: .navigation) { SettingsMenu() }
				#if os(iOS)
					// macOS renders the wordmark inline above the dial (the
					// title-bar `.principal` slot competes with the window
					// chrome and looks out of place there).
					ToolbarItem(placement: .principal) { ToolbarLogo() }
				#endif
				ToolbarItem(placement: .trailingAction) {
					EmbeddingProgressIndicator(progress: .shared)
				}
				ToolbarItem(placement: .trailingAction) {
					Button {
						showingHistory = true
					} label: {
						Label("History", systemImage: "clock.arrow.circlepath")
					}
				}
			}
			.sheet(isPresented: $showingHistory) {
				HistoryView()
			}
			.sensoryFeedback(.impact(weight: .medium), trigger: dial.spinLandTick)
			// Trigger on the focused song's *id*, not its index — a
			// reanchor (e.g. walk-controls change keeping the same song
			// focused at a new position) changes the index while
			// keeping the same song focused, and the user shouldn't
			// feel a haptic for that.
			.sensoryFeedback(.selection, trigger: dial.focusedItemID)
			.sensoryFeedback(.start, trigger: dial.playbackTick)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized, !hasBuiltDeck {
					Task { await buildDeck() }
				}
			}
			.onChange(of: dial.focusedIndex) { _, newIdx in
				guard !dial.isSpinning, newIdx >= 0, newIdx < deck.count else { return }
				dial.focusedItemID = deck[newIdx].id
			}
			.overlay {
				LibraryStateOverlay(
					isEmpty: deck.isEmpty,
					isLoading: isLoading,
					loadError: loadError,
					emptyMessage: "No songs yet",
					emptyHint: "Pull to refresh once your library has more history."
				)
			}
		}
	}

	private var reshuffleLoadingView: some View {
		VStack(spacing: 16) {
			ProgressView()
				.controlSize(.large)
			CyclingLoadingText()
				.font(.callout)
				.foregroundStyle(.secondary)
		}
	}

	// MARK: - Deck building

	private func buildDeck() async {
		isLoading = true
		loadError = nil
		defer { isLoading = false }
		// Pre-position the dial off-center BEFORE the deck arrives. If we
		// instead set rotation in applyDeck (when items first land), the
		// rotation mutation and the deck mutation flush in the same SwiftUI
		// render pass and the dial visibly spins from 0 to the landing
		// position. Setting rotation here — while the dial has no items and
		// is still hidden behind the loading overlay — means the dial
		// renders at its final position the moment the overlay clears.
		// Guard: only on first build, so pull-to-refresh doesn't re-randomize.
		if dial.focusedItemID == nil {
			// Cold-launch pre-position uses the base spread — we don't know
			// the deck count yet, and this is a one-shot landing (the
			// shuffle path is what `landingSpread(forCount:)` widens).
			let offset = Int.random(in: -Self.baseLandingSpread ... Self.baseLandingSpread)
			dial.rotation = .degrees(-Double(offset) * DialTunables.stepVisual)
		}
		await runBuild(wideSample: false)
	}

	private func runBuild(
		wideSample: Bool,
		avoidDecade: Int? = nil,
		avoidArtist: String? = nil
	) async {
		// `buildStreaming` yields exactly once with the finished deck.
		// The for-await shape is kept so cancellation still propagates
		// through `onTermination` if the task is cancelled mid-build.
		do {
			for try await result in GemDeckBuilder.buildStreaming(
				wideSample: wideSample,
				controls: walkControls,
				avoidDecade: avoidDecade,
				avoidArtist: avoidArtist
			) {
				applyDeck(result.deck)
				if let bounds = result.libraryDecadeBounds {
					libraryDecadeBounds = bounds
				}
				lastBuildOriginals = result.originals
			}
			// `AsyncThrowingStream` returns `nil` from `.next()` on
			// consumer cancellation instead of throwing — so a tab
			// switch mid-build exits the loop without yielding *and*
			// without routing through the `catch`. Without this guard
			// we'd then run the post-loop code, set `hasBuiltDeck =
			// true` against an empty deck, and leave the user stuck on
			// "No songs yet" with no way to retry.
			if Task.isCancelled { return }
			// Seed the toolbar progress tracker with the final deck.
			// The background warm task (kicked off inside GemDeckBuilder)
			// will then drive `recordProcessed` calls into it as each song's
			// embedding lands or is given up on.
			let deckIDs = deck.map(\.id)
			let existing = await EmbeddingStore.shared.embeddings(for: deckIDs)
			EmbeddingProgress.shared.setTracking(
				songIDs: deckIDs,
				existing: Set(existing.keys.map(\.rawValue))
			)
			hasBuiltDeck = true
		} catch {
			loadError = "Couldn't load songs: \(error.localizedDescription)"
		}
	}

	private func applyDeck(_ songs: [Song]) {
		let preservedID = dial.focusedItemID
		let newCollection = MusicItemCollection<Song>(songs)
		let newIdx = preservedID.flatMap { id in newCollection.firstIndex(where: { $0.id == id }) }

		let unchanged = deck.count == newCollection.count
			&& zip(deck, newCollection).allSatisfy { $0.id == $1.id }

		if unchanged {
			deck = newCollection
		} else {
			withAnimation(.smooth(duration: 0.5)) { deck = newCollection }
		}

		if newCollection.isEmpty {
			dial.clear()
		} else if let newIdx {
			dial.reanchor(to: newIdx, newID: newCollection[newIdx].id, count: newCollection.count)
		} else if preservedID == nil {
			// Cold launch. Rotation was pre-positioned in buildDeck before
			// this fired — derive the landing index from it so the dial
			// renders in its final position without animating from 0.
			let landingIdx = Self.landingIndex(forRotation: dial.rotation, count: newCollection.count)
			dial.focusedIndex = landingIdx
			dial.focusedItemID = newCollection[landingIdx].id
		} else {
			// Had a focus but the song isn't in the new deck (typically
			// shuffle replacing the candidate pool). The dial is hidden
			// behind the reshuffle overlay during that path, so changing
			// rotation here isn't visible.
			let landingIdx = Self.randomLandingIndex(count: newCollection.count)
			dial.focusedIndex = landingIdx
			dial.rotation = .degrees(-Double(landingIdx) * DialTunables.stepVisual)
			dial.focusedItemID = newCollection[landingIdx].id
		}
	}

	private static func landingIndex(forRotation rotation: Angle, count: Int) -> Int {
		guard count > 0 else { return 0 }
		let continuousPos = -rotation.degrees / DialTunables.stepVisual
		let raw = Int(continuousPos.rounded())
		return ((raw % count) + count) % count
	}

	/// How far around the walk's seed the dial may land on a fresh deck.
	/// Originally a flat 6, which gave 13 landing slots regardless of
	/// deck size — fine for a 300-song deck on the default filters but
	/// thin under "energy + narrow decade," where the surviving pool
	/// might only be ~100 songs and the user kept seeing the same
	/// cluster head shuffle after shuffle. Scale with deck size so the
	/// landing window grows as the deck does, capped so the dial still
	/// drops the user somewhere in the walk's early section rather
	/// than into the dissimilar tail.
	private static let baseLandingSpread = 6
	private static let maxLandingSpread = 40

	private static func landingSpread(forCount count: Int) -> Int {
		max(baseLandingSpread, min(count / 6, maxLandingSpread))
	}

	private static func randomLandingIndex(count: Int) -> Int {
		guard count > 1 else { return 0 }
		let spread = landingSpread(forCount: count)
		let offset = Int.random(in: -spread ... spread)
		return ((offset % count) + count) % count
	}

	/// Move the dial to a fresh landing on the current deck. Used by
	/// shuffle to override `applyDeck`'s reanchor when the previously-
	/// focused song happens to survive the new deck. Safe to call while
	/// the dial is hidden behind the reshuffle overlay — rotation is set
	/// without animation, so it's the position that's revealed when the
	/// overlay clears.
	private func relandRandomly() {
		guard !deck.isEmpty else { return }
		let landingIdx = Self.randomLandingIndex(count: deck.count)
		dial.focusedIndex = landingIdx
		dial.rotation = .degrees(-Double(landingIdx) * DialTunables.stepVisual)
		dial.focusedItemID = deck[landingIdx].id
	}

	// MARK: - Shuffle

	/// Songs-mode shuffle = full deck rebuild. Spinning the wheel within
	/// the current deck just re-walks the same 300 songs in roughly the
	/// same neighborhood; rebuilding actually turns over the candidate
	/// pool. The dial blurs out to a loading view, the new deck is
	/// fetched and walked, and the dial blurs back in.
	private func shuffle() async {
		guard !dial.isSpinning, !isReshuffling else { return }
		// Tell the walk to seed away from the previous shuffle's
		// neighbourhood — without this, a library skewed toward one
		// era keeps landing on that era's cluster shuffle after shuffle.
		let avoidDecade = lastShuffleDecade
		let avoidArtist = lastShuffleArtist
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = true }
		await runBuild(
			wideSample: true,
			avoidDecade: avoidDecade,
			avoidArtist: avoidArtist
		)
		// Force a fresh landing. `applyDeck`'s reanchor branch keeps
		// focus on the previously-focused song whenever it survives the
		// new wide-sample deck — fine during the partial→final swap
		// (dial is hidden), but it defeats the whole point of shuffle.
		// On an unfiltered library the previously-focused song is
		// almost always in the new top 300 (high gem score → in widePool
		// → ~50% inclusion probability; if `capPerArtistAndAlbum`
		// trims widePool to ≤300 the inclusion becomes deterministic),
		// so shuffle would feel like a no-op without this.
		relandRandomly()
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = false }
		// Record the *focused* song — what the dial actually landed on —
		// not `deck.first`. The user sees `deck[landingIdx]`, which sits
		// in the walk's first-few-positions cluster but often differs in
		// artist/decade from the seed. Tracking the seed instead meant
		// the next shuffle could jump the *seed*'s neighbourhood while
		// still landing the user back in the same cluster head.
		if let focused = focusedSong {
			lastShuffleDecade = focused.releaseDecade(override: lastBuildOriginals[focused.id])
			lastShuffleArtist = focused.artistName
		}
		// Detached: same rationale as PlaylistsView.shuffle — the rebuild is
		// the visible work; the queue handoff to MusicPlayback shouldn't
		// keep the Shuffle button busy.
		if autoplay, let song = focusedSong {
			Task { await play(from: song) }
		}
	}

	/// Triggered when the walk-controls popover dismisses with changes.
	/// Reuses the reshuffle blur path (not wideSample — energy/decade
	/// changes already turn the deck over) so the swap feels intentional
	/// rather than mid-flight.
	private func rebuildForWalkControlsChange() async {
		guard !dial.isSpinning, !isReshuffling else { return }
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = true }
		await runBuild(wideSample: false)
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = false }
	}

	// MARK: - Removal

	/// Per-cover context menu. Each action flags the song / album / artist
	/// ineligible for future decks (via `ExclusionStore`) and drops the
	/// matching covers from the live deck so the change is immediate.
	@ViewBuilder
	private func songContextMenu(for song: Song) -> some View {
		Button(role: .destructive) {
			Task { await removeSong(song) }
		} label: {
			Label("Remove Song", systemImage: "minus.circle")
		}
		if let album = song.albumTitle, !album.isEmpty {
			Button(role: .destructive) {
				Task { await removeAlbum(song) }
			} label: {
				Label("Remove Album", systemImage: "rectangle.stack.badge.minus")
			}
		}
		Button(role: .destructive) {
			Task { await removeArtist(song) }
		} label: {
			Label("Remove Artist", systemImage: "person.crop.circle.badge.minus")
		}
	}

	private func removeSong(_ song: Song) async {
		applyDeckRemoval { $0.id == song.id }
		await ExclusionStore.shared.blockSong(
			id: song.id.rawValue,
			label: "\(song.title) — \(song.artistName)"
		)
	}

	private func removeAlbum(_ song: Song) async {
		guard let album = song.albumTitle, !album.isEmpty else { return }
		applyDeckRemoval { $0.artistName == song.artistName && $0.albumTitle == album }
		await ExclusionStore.shared.blockAlbum(
			artist: song.artistName,
			title: album,
			label: "\(album) — \(song.artistName)"
		)
	}

	private func removeArtist(_ song: Song) async {
		applyDeckRemoval { $0.artistName == song.artistName }
		await ExclusionStore.shared.blockArtist(name: song.artistName, label: song.artistName)
	}

	/// Drop every deck song matching `shouldRemove`, animating the covers
	/// out and re-anchoring the dial. Mirrors `applyDeck`'s reanchor
	/// pattern (data change animates via blur-replace; rotation is set
	/// instantly through `reanchoredRotation` so the wheel doesn't
	/// teleport) — but this path is visible, so a removed focus lands on
	/// the song that shifts into its slot rather than a random jump.
	private func applyDeckRemoval(_ shouldRemove: (Song) -> Bool) {
		let remaining = deck.filter { !shouldRemove($0) }
		guard remaining.count != deck.count else { return }

		let preservedID = dial.focusedItemID
		let oldIdx = dial.focusedIndex
		let newCollection = MusicItemCollection<Song>(remaining)

		withAnimation(.smooth(duration: 0.4)) { deck = newCollection }

		if newCollection.isEmpty {
			dial.clear()
		} else if let id = preservedID, let idx = newCollection.firstIndex(where: { $0.id == id }) {
			dial.reanchor(to: idx, newID: newCollection[idx].id, count: newCollection.count)
		} else {
			let target = max(0, min(oldIdx, newCollection.count - 1))
			dial.reanchor(to: target, newID: newCollection[target].id, count: newCollection.count)
		}
	}

	// MARK: - Playback

	/// Seed the system queue with the picked song + the next 19 deck items
	/// so playback keeps flowing without us having to babysit `queue.insert`
	/// on every track end.
	private func play(from song: Song) async {
		// Diagnostic: songs with nil playParameters get silently skipped
		// by SystemMusicPlayer (rights lapsed, lost cloud match, region-
		// locked, etc). GemScorer filters these out of the candidate
		// pool already, so reaching this log means a song landed in the
		// deck that shouldn't have — worth checking the song in Apple
		// Music to understand why.
		if song.playParameters == nil {
			print("Songs: skipping \(song.title) — \(song.artistName); nil playParameters")
		}

		// Wrap modularly around the deck. The dial is a cylinder, so
		// landing near the tail (e.g. position 296 after randomLandingIndex
		// picks a negative offset) should still produce a 20-song runway —
		// continue from the start of the deck once we fall off the end,
		// not truncate to whatever happens to be ahead.
		guard let startIdx = deck.firstIndex(where: { $0.id == song.id }) else { return }
		let runwayLength = min(20, deck.count)
		let runway = (0 ..< runwayLength).map { offset in
			deck[(startIdx + offset) % deck.count]
		}
		guard !runway.isEmpty else { return }

		guard await MusicPlayback.play(songs: runway) else { return }
		dial.markPlaying(id: song.id)

		// Record only after playback started — no point remembering a runway
		// that errored on the way out the door.
		let seedSnapshot = SongSnapshot(song: song)
		let runwaySnapshots = runway.map(SongSnapshot.init(song:))
		let name = PlaylistNamer.suggestedName(seedArtist: song.artistName)
		await HistoryStore.shared.record(
			name: name,
			seed: seedSnapshot,
			runway: runwaySnapshots
		)
	}

	private func open(_ song: Song) {
		// Library-only songs (no Apple Music catalog match — iTunes Match
		// uploads, personal files) have a nil `Song.url`, so the existing
		// guard would silently bail. The iOS Music app's library deep-link
		// scheme handles them by MusicKit id. The same URL form errors on
		// macOS Music ("Sorry, something went wrong"), so the fallback is
		// iOS-only — on macOS, catalog-matched songs still open via
		// `song.url`, library-only ones no-op.
		var url: URL? = song.url
		#if os(iOS)
			if url == nil {
				url = URL(string: "music://music.apple.com/library/song/\(song.id)")
			}
		#endif
		guard let url else { return }
		openURL(url)
	}
}

#Preview {
	SongsView()
}
