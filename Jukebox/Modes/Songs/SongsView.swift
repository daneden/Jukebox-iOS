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
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.allowsHitTesting(!dial.isSpinning)

				if let song = focusedSong, !dial.isSpinning {
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
					disabled: dial.isSpinning || deck.isEmpty,
					onPlay: { if let s = focusedSong { await play(from: s) } },
					onShuffle: { await shuffle() },
					onSuperShuffle: { await superShuffle() }
				)
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { SettingsMenu() }
				ToolbarItem(placement: .principal) { ToolbarLogo() }
				ToolbarItem(placement: .topBarTrailing) {
					EmbeddingProgressIndicator(progress: .shared)
				}
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
					loadingMessage: "Searching your library for gems…",
					emptyMessage: "No gems yet",
					emptyHint: "Pull to refresh once your library has more history.",
					authMessage: "Jukebox needs access to your Apple Music library to find your hidden gems."
				)
			}
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

	/// Force a fresh deck by widening the candidate slice and resampling.
	/// Same songs in the same library produce a different deck each time,
	/// so the dial genuinely turns over rather than just re-walking the
	/// same top-300 in a new order. Doesn't toggle `isLoading` — the
	/// current deck stays visible until the new one lifts in via the
	/// existing partial/final transitions.
	private func superShuffle() async {
		guard !dial.isSpinning else { return }
		await runBuild(wideSample: true)
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
			dial.focusedIndex = 0
			dial.rotation = .zero
			dial.focusedItemID = newCollection.first?.id
		}
	}

	// MARK: - Shuffle

	private func shuffle() async {
		guard let target = DialMechanics.shuffleTarget(
			currentFocus: dial.focusedIndex,
			itemCount: deck.count
		) else { return }

		let destination = DialMechanics.spinDestination(
			current: dial.rotation,
			target: target,
			count: deck.count
		)
		let duration = DialTunables.shuffleDuration(
			degrees: destination.degrees - dial.rotation.degrees
		)

		dial.isSpinning = true
		withAnimation(.spring(duration: duration, bounce: DialTunables.shuffleSpringBounce)) {
			dial.rotation = destination
		}
		try? await Task.sleep(for: .seconds(duration))
		dial.isSpinning = false

		let chosen = deck[target]
		dial.recordLanding(at: target, id: chosen.id)

		if autoplay { await play(from: chosen) }
	}

	// MARK: - Playback

	/// Seed the system queue with the picked song + the next 19 deck items
	/// so playback keeps flowing without us having to babysit `queue.insert`
	/// on every track end.
	private func play(from song: Song) async {
		let runway = Array(deck.drop(while: { $0.id != song.id }).prefix(20))
		guard !runway.isEmpty else { return }
		do {
			SystemMusicPlayer.shared.queue = .init(for: runway)
			try await SystemMusicPlayer.shared.play()
			dial.markPlaying(id: song.id)
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
