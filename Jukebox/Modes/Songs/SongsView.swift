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

	@State private var deck: MusicItemCollection<Song> = []
	@State private var dial = DialState()

	@State private var isLoading: Bool = true
	@State private var loadError: String?
	@State private var hasBuiltDeck = false
	@State private var showingHistory = false
	/// True while a shuffle-driven rebuild is in flight. The dial is
	/// pulled offscreen for the duration so partial/final deck swaps
	/// don't visibly thrash; a loading view sits in its place.
	@State private var isReshuffling = false

	private var focusedSong: Song? {
		guard !deck.isEmpty,
		      dial.focusedIndex >= 0,
		      dial.focusedIndex < deck.count else { return nil }
		return deck[dial.focusedIndex]
	}

	var body: some View {
		NavigationView {
			VStack(spacing: 0) {
				Spacer(minLength: 0)

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
							placeholderSymbol: "music.note"
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

				if let song = focusedSong, !dial.isSpinning, !isReshuffling {
					titleBlock(song)
				}

				Spacer(minLength: 0)
			}
			.animation(.easeInOut(duration: 0.25), value: focusedSong?.id)
			.task(id: scenePhase) {
				if scenePhase == .active, !hasBuiltDeck { await buildDeck() }
			}
			.refreshable { await buildDeck() }
			.safeAreaBar(edge: .bottom, alignment: .trailing) {
				PlaybackControls(
					disabled: dial.isSpinning || deck.isEmpty || isReshuffling,
					onPlay: { if let s = focusedSong { await play(from: s) } },
					onShuffle: { await shuffle() }
				)
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { SettingsMenu() }
				ToolbarItem(placement: .principal) { ToolbarLogo() }
				ToolbarItem(placement: .topBarTrailing) {
					EmbeddingProgressIndicator(progress: .shared)
				}
				ToolbarItem(placement: .topBarTrailing) {
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
			// reanchor (e.g. partial → final deck swap during streaming)
			// changes the index while keeping the same song focused, and
			// the user shouldn't feel a haptic for that.
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
					emptyMessage: "No gems yet",
					emptyHint: "Pull to refresh once your library has more history.",
					authMessage: "Jukebox needs access to your Apple Music library to find your hidden gems."
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

	private func titleBlock(_ song: Song) -> some View {
		VStack(spacing: 4) {
			Text(song.title)
				.font(.title2)
				.fontWeight(.semibold)
				.multilineTextAlignment(.center)
				.lineLimit(2)

			Text(song.artistName)
				.font(.subheadline)
				.foregroundStyle(.secondary)
		}
		.id(song.id)
		.contentTransition(.numericText())
		.padding(.horizontal, 24)
		.padding(.bottom, 24)
		.contentShape(.rect)
		.onTapGesture { open(song) }
		.transition(.blurReplace)
	}

	// MARK: - Deck building

	private func buildDeck() async {
		isLoading = true
		loadError = nil
		defer { isLoading = false }
		await runBuild(wideSample: false)
	}

	private func runBuild(wideSample: Bool) async {
		// Stream partial → final from GemDeckBuilder. The first emission is
		// the nostalgia-only deck (lands fast, dial becomes interactive);
		// the second is the full nostalgia+discovery deck (lift-out
		// transition swaps it in when ready).
		do {
			for try await result in GemDeckBuilder.buildStreaming(wideSample: wideSample) {
				applyDeck(result.deck)
			}
			// Seed the toolbar progress tracker with the final deck.
			// The background warm task (kicked off inside GemDeckBuilder)
			// will then drive `recordEmbedded` calls into it as each song's
			// embedding lands.
			let deckIDs = deck.map(\.id)
			let existing = await EmbeddingStore.shared.embeddings(for: deckIDs)
			EmbeddingProgress.shared.setTracking(
				songIDs: deckIDs,
				existing: Set(existing.keys.map(\.rawValue))
			)
			hasBuiltDeck = true
		} catch {
			loadError = "Couldn't load gems: \(error.localizedDescription)"
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
		} else {
			// Land at a random offset around the walk's seed (position 0)
			// rather than always at the seed itself. Otherwise every
			// reshuffle surfaces the same #1 gem and the top of the deck
			// feels repetitive; an offset of ±landingSpread keeps the
			// landing within the seed's sonic neighborhood (the walk's
			// greedy similarity ordering puts the closest neighbors
			// nearby in both directions around 0 modulo count).
			let landingIdx = Self.randomLandingIndex(count: newCollection.count)
			dial.focusedIndex = landingIdx
			dial.rotation = .degrees(-Double(landingIdx) * DialTunables.stepVisual)
			dial.focusedItemID = newCollection[landingIdx].id
		}
	}

	/// How far around the walk's seed the dial may land on a fresh deck.
	/// Tunable; 6 keeps the landing in the seed's similarity neighborhood
	/// (the first ~6 walk steps are all close to the seed) while giving
	/// 13 possible landing slots — enough variety that consecutive
	/// reshuffles feel different.
	private static let landingSpread = 6

	private static func randomLandingIndex(count: Int) -> Int {
		guard count > 1 else { return 0 }
		let offset = Int.random(in: -Self.landingSpread ... Self.landingSpread)
		return ((offset % count) + count) % count
	}

	// MARK: - Shuffle

	/// Songs-mode shuffle = full deck rebuild. Spinning the wheel within
	/// the current deck just re-walks the same 300 songs in roughly the
	/// same neighborhood; rebuilding actually turns over the candidate
	/// pool. The dial blurs out to a loading view, the new deck is
	/// fetched and walked, and the dial blurs back in.
	private func shuffle() async {
		guard !dial.isSpinning, !isReshuffling else { return }
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = true }
		await runBuild(wideSample: true)
		withAnimation(.smooth(duration: 0.45)) { isReshuffling = false }
		if autoplay, let song = focusedSong {
			await play(from: song)
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
		do {
			SystemMusicPlayer.shared.queue = .init(for: runway)
			try await SystemMusicPlayer.shared.play()
			dial.markPlaying(id: song.id)

			// Log the runway after playback actually starts — no point
			// remembering a "playlist" that errored on the way out the door.
			let seedSnapshot = SongSnapshot(song: song)
			let runwaySnapshots = runway.map(SongSnapshot.init(song:))
			let name = PlaylistNamer.suggestedName(seedArtist: song.artistName)
			await HistoryStore.shared.record(
				name: name,
				seed: seedSnapshot,
				runway: runwaySnapshots
			)
		} catch {
			print("Songs playback error: \(error)")
		}
	}

	private func open(_ song: Song) {
		guard let url = song.url else { return }
		openURL(url)
	}
}

#Preview {
	SongsView()
}
