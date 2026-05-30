//
//  SongsView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Songs (hidden-gems) mode. Builds a curated deck of dormant/old songs and
/// rides the same dial as Playlists mode. On play, seeds the system queue
/// with a 20-song runway so playback keeps flowing.
struct SongsView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true
	@AppStorage(SettingsKeys.walkMeander) private var meander: Double = WalkControls.default.meander
	// -1 is the "no filter" sentinel — AppStorage can't hold an optional.
	@AppStorage(SettingsKeys.walkEnergyTarget) private var energyTarget: Double = -1
	@AppStorage(SettingsKeys.walkEnergyWindow) private var energyWindow: Double = EnergyFilter.defaultWindow
	@AppStorage(SettingsKeys.walkDecadeLower) private var decadeLower: Int = WalkControls.default.decadeRange.lower
	@AppStorage(SettingsKeys.walkDecadeUpper) private var decadeUpper: Int = WalkControls.default.decadeRange.upper

	@State private var deck: MusicItemCollection<Song> = []
	@State private var dial = DialState()

	@State private var isLoading: Bool = true
	@State private var loadError: String?
	@State private var hasBuiltDeck = false
	@State private var showingWalkControls = false
	/// Captured at popover-open so dismiss can skip the rebuild if nothing changed.
	@State private var walkControlsAtOpen: WalkControls?
	/// True while a shuffle rebuild is in flight; the dial is pulled
	/// offscreen so the deck swap doesn't visibly thrash.
	@State private var isReshuffling = false
	/// Previous shuffle's neighbourhood, fed back so the seed picker jumps
	/// away — without it a heavily-oldies library keeps landing the same cluster.
	@State private var lastShuffleDecade: Int?
	@State private var lastShuffleArtist: String?
	/// Min/max decades in the unfiltered pool, so the range slider can
	/// constrain its thumbs to decades that exist in the library.
	@State private var libraryDecadeBounds: ClosedRange<Int>?
	/// `OriginalReleaseStore` snapshot from the latest build, so the
	/// shuffle-avoid hint reads a focused song's original decade without an actor hop.
	@State private var lastBuildOriginals: [MusicItemID: Date] = [:]

	private var walkControls: WalkControls {
		WalkControls(
			meander: meander,
			energy: EnergyFilter(target: energyTarget < 0 ? nil : energyTarget, window: energyWindow),
			decadeRange: DecadeRange(lower: decadeLower, upper: decadeUpper)
		)
	}

	private var walkControlsBinding: Binding<WalkControls> {
		Binding(
			get: { walkControls },
			set: { new in
				meander = new.meander
				energyTarget = new.energy.target ?? -1
				energyWindow = new.energy.window
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

	/// `focusedSong` only while the dial is at rest, so the title block
	/// empties out during shuffle instead of disappearing and shifting layout.
	private var settledSong: Song? {
		(dial.isSpinning || isReshuffling) ? nil : focusedSong
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
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
				// Scoped to the title block on purpose — on the parent VStack
				// it also animates `DialContent`'s `animatableData: rotation`,
				// visibly spinning the dial on cold launch.
				.animation(.easeInOut(duration: 0.25), value: settledSong?.id)

				Spacer(minLength: 0)
			}
			.task(id: scenePhase) {
				if scenePhase == .active, !hasBuiltDeck { await buildDeck() }
			}
			.refreshable { await buildDeck() }
			.tabHeader(tip: SongsTip())
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
					.disabled(dial.isSpinning || isReshuffling)
					.popover(isPresented: $showingWalkControls) {
						WalkControlsPopover(
							controls: walkControlsBinding,
							libraryDecadeBounds: libraryDecadeBounds,
							poolSize: hasBuiltDeck ? deck.count : nil
						)
						// Adapt to a sheet on compact (iPhone) — the popover
						// frame is too cramped on phone-sized screens.
						.presentationCompactAdaptation(.sheet)
						.presentationDetents([.medium, .large])
						.presentationDragIndicator(.visible)
					}
				}
			}
			.onChange(of: showingWalkControls) { wasShowing, nowShowing in
				// Rebuild on dismiss, not per-slider-step, so scrubbing doesn't thrash the deck.
				if wasShowing, !nowShowing,
				   let snap = walkControlsAtOpen, snap != walkControls
				{
					walkControlsAtOpen = nil
					Task { await rebuildForWalkControlsChange() }
				}
			}
			.primaryToolbar()
			.sensoryFeedback(.impact(weight: .medium), trigger: dial.spinLandTick)
			// Trigger on the song's id, not its index — a reanchor changes
			// the index while keeping the same song focused; no haptic for that.
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
		// Pre-position rotation BEFORE the deck arrives. Setting it in
		// applyDeck instead flushes the rotation and deck mutations in one
		// render pass, visibly spinning the dial from 0. Only on first build,
		// so pull-to-refresh doesn't re-randomize.
		if dial.focusedItemID == nil {
			// Base spread: deck count is unknown here, and this is a one-shot
			// landing (shuffle is what widens via `landingSpread(forCount:)`).
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
		// `buildStreaming` yields once; the for-await shape is kept so
		// cancellation still propagates through `onTermination` mid-build.
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
			// `AsyncThrowingStream` returns nil from `.next()` on consumer
			// cancellation instead of throwing, so a mid-build tab switch
			// exits the loop without routing through `catch`. Without this
			// guard the post-loop code sets `hasBuiltDeck = true` on an empty
			// deck, stranding the user on "No songs yet".
			if Task.isCancelled { return }
			// Seed the toolbar progress tracker; the warm task then drives
			// `recordProcessed` as each embedding lands or is given up on.
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
			// Cold launch. Rotation was pre-positioned in buildDeck — derive
			// the landing index from it so the dial renders in place, not from 0.
			let landingIdx = Self.landingIndex(forRotation: dial.rotation, count: newCollection.count)
			dial.focusedIndex = landingIdx
			dial.focusedItemID = newCollection[landingIdx].id
		} else {
			// Focused song dropped from the new deck (typically shuffle).
			// The dial is hidden behind the reshuffle overlay, so the
			// rotation change here isn't visible.
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
	/// `landingSpread(forCount:)` scales with deck size — a flat spread left
	/// narrow-filter pools cycling the same cluster head — capped so the
	/// landing stays in the walk's early section, not the dissimilar tail.
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

	/// Move the dial to a fresh landing, overriding `applyDeck`'s reanchor
	/// when the focused song survives the new deck. Safe while hidden behind
	/// the reshuffle overlay — rotation is set without animation.
	private func relandRandomly() {
		guard !deck.isEmpty else { return }
		let landingIdx = Self.randomLandingIndex(count: deck.count)
		dial.focusedIndex = landingIdx
		dial.rotation = .degrees(-Double(landingIdx) * DialTunables.stepVisual)
		dial.focusedItemID = deck[landingIdx].id
	}

	// MARK: - Shuffle

	/// Songs-mode shuffle = full deck rebuild. Re-walking the current deck
	/// just reorders the same 300 songs; rebuilding turns over the candidate
	/// pool. The dial blurs out, the new deck is fetched, and it blurs back.
	private func shuffle() async {
		guard !dial.isSpinning, !isReshuffling else { return }
		// Seed away from the previous shuffle's neighbourhood — without this,
		// an era-skewed library keeps landing the same cluster.
		let avoidDecade = lastShuffleDecade
		let avoidArtist = lastShuffleArtist
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = true }
		await runBuild(
			wideSample: true,
			avoidDecade: avoidDecade,
			avoidArtist: avoidArtist
		)
		// Force a fresh landing. `applyDeck` keeps focus on the previous
		// song when it survives the new deck — which it almost always does
		// on an unfiltered library, so shuffle would feel like a no-op.
		relandRandomly()
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = false }
		// Record the focused song (what the dial landed on), not the seed —
		// they differ, and tracking the seed let the next shuffle jump the
		// seed's neighbourhood while still landing the same cluster head.
		if let focused = focusedSong {
			lastShuffleDecade = focused.releaseDecade(override: lastBuildOriginals[focused.id])
			lastShuffleArtist = focused.artistName
		}
		// Detached so the queue handoff doesn't keep the Shuffle button busy.
		if autoplay, let song = focusedSong {
			Task { await play(from: song) }
		}
	}

	/// Rebuild when the walk-controls popover dismisses with changes. Reuses
	/// the reshuffle blur path but not wideSample — the filter change already
	/// turns the deck over.
	private func rebuildForWalkControlsChange() async {
		guard !dial.isSpinning, !isReshuffling else { return }
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = true }
		await runBuild(wideSample: false)
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = false }
	}

	// MARK: - Removal

	/// Per-cover context menu. Each action flags the song/album/artist
	/// ineligible (via `ExclusionStore`) and drops matching covers immediately.
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

	/// Drop deck songs matching `shouldRemove`, animating covers out and
	/// reanchoring the dial. Unlike `applyDeck`, this path is visible, so a
	/// removed focus lands on the song shifting into its slot, not a random jump.
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

	/// Seed the system queue with the picked song + next 19 deck items so
	/// playback keeps flowing without babysitting `queue.insert` per track.
	private func play(from song: Song) async {
		// nil playParameters → silently skipped by SystemMusicPlayer. GemScorer
		// already filters these out, so reaching this log means a song slipped
		// into the deck that shouldn't have.
		if song.playParameters == nil {
			print("Songs: skipping \(song.title) — \(song.artistName); nil playParameters")
		}

		// Wrap modularly: the dial is a cylinder, so a tail landing still
		// gets a full 20-song runway by continuing from the deck's start.
		guard let startIdx = deck.firstIndex(where: { $0.id == song.id }) else { return }
		let runwayLength = min(20, deck.count)
		let runway = (0 ..< runwayLength).map { offset in
			deck[(startIdx + offset) % deck.count]
		}
		guard !runway.isEmpty else { return }

		guard await MusicPlayback.play(songs: runway) else { return }
		dial.markPlaying(id: song.id)

		// Record only after playback started — don't remember a runway that errored.
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
		// Library-only songs (iTunes Match, personal files) have a nil
		// `Song.url`; the iOS Music library deep-link scheme opens them by id.
		// The same URL errors on macOS Music ("Sorry, something went wrong"),
		// so the fallback is iOS-only and library-only songs no-op on macOS.
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
