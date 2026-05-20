//
//  EndlessView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Endless / hidden-gems mode. Builds a curated deck of songs from the user's
/// library (formerly-played-now-dormant + old-and-untouched), feeds them
/// through the same dial UI as Playlists mode, and seeds the system queue with
/// a runway of upcoming gems on play so playback keeps flowing when the user
/// puts the phone down.
struct EndlessView: View {
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true

	@State private var deck: MusicItemCollection<Song> = []

	@State private var rotation: Angle = .zero
	@State private var focusedIndex: Int = 0
	@State private var focusedSongID: MusicItemID?
	@State private var spinLandTick: Int = 0
	@State private var isSpinning: Bool = false
	@State private var rippleCounters: [MusicItemID: Int] = [:]

	@State private var isLoading: Bool = true
	@State private var loadError: String?
	@State private var hasBuiltDeck = false

	private var focusedSong: Song? {
		guard !deck.isEmpty,
		      focusedIndex >= 0,
		      focusedIndex < deck.count else { return nil }
		return deck[focusedIndex]
	}

	var body: some View {
		NavigationView {
			VStack(spacing: 0) {
				Spacer(minLength: 0)

				DialView(
					items: deck,
					rotation: $rotation,
					focusedIndex: $focusedIndex,
					rippleCounters: rippleCounters,
					placeholderSymbol: "music.note"
				) {
					if let song = focusedSong {
						Task { await play(from: song) }
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.allowsHitTesting(!isSpinning)

				if let song = focusedSong, !isSpinning {
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

				Spacer(minLength: 0)
			}
			.animation(.easeInOut(duration: 0.25), value: focusedSong?.id)
			.task(id: scenePhase) {
				switch scenePhase {
				case .active:
					if !hasBuiltDeck { await buildDeck() }
				default: break
				}
			}
			.refreshable {
				await buildDeck()
			}
			.safeAreaBar(edge: .bottom, alignment: .trailing) {
				PlaybackControls(
					disabled: isSpinning || deck.isEmpty,
					onPlay: {
						if let song = focusedSong {
							await play(from: song)
						}
					},
					onShuffle: { await shuffle() }
				)
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					SettingsMenu()
				}
				ToolbarItem(placement: .principal) {
					Image(.playback)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(height: 64)
						.foregroundStyle(.primary)
				}
			}
			.sensoryFeedback(.impact(weight: .medium), trigger: spinLandTick)
			.sensoryFeedback(.selection, trigger: focusedIndex)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized, !hasBuiltDeck {
					Task { await buildDeck() }
				}
			}
			.onChange(of: focusedIndex) { _, newIdx in
				guard !isSpinning, newIdx >= 0, newIdx < deck.count else { return }
				focusedSongID = deck[newIdx].id
			}
			.overlay {
				switch MusicAuthorization.currentStatus {
				case .notDetermined:
					VStack {
						Spacer()
						Text("Get Started")
							.font(.headline)
						Text("Jukebox needs access to your Apple Music library to find your hidden gems.")
						Button("Allow Access") {
							Task { await MusicAuthorization.request() }
						}
						.buttonStyle(.borderedProminent)
						Spacer()
					}
					.scenePadding()
				case .authorized:
					if deck.isEmpty {
						VStack(spacing: 12) {
							Spacer()
							if isLoading {
								ProgressView()
									.controlSize(.large)
								Text("Searching your library for gems…")
									.font(.subheadline)
									.foregroundStyle(.secondary)
							} else if let loadError {
								Text(loadError)
									.foregroundStyle(.secondary)
							} else {
								Text("No gems yet")
									.foregroundStyle(.secondary)
								Text("Pull to refresh once your library has more history.")
									.font(.footnote)
									.foregroundStyle(.tertiary)
									.multilineTextAlignment(.center)
							}
							Spacer()
						}
						.transition(.opacity)
						.scenePadding()
					}
				default:
					EmptyView()
				}
			}
		}
	}

	// MARK: - Deck building

	private func buildDeck() async {
		isLoading = true
		loadError = nil
		defer { isLoading = false }

		do {
			let result = try await GemDeckBuilder.build()
			applyDeck(result.deck)
			hasBuiltDeck = true
		} catch {
			loadError = "Couldn't load gems: \(error.localizedDescription)"
		}
	}

	private func applyDeck(_ songs: [Song]) {
		let preservedID: MusicItemID? = focusedSongID
		let newCollection = MusicItemCollection<Song>(songs)
		let newIdx: Int? = preservedID.flatMap { id in
			newCollection.firstIndex(where: { $0.id == id })
		}

		withAnimation {
			self.deck = newCollection
		}

		if newCollection.isEmpty {
			focusedIndex = 0
			rotation = .zero
			focusedSongID = nil
		} else if let newIdx {
			reanchor(to: newIdx, in: newCollection)
		} else {
			focusedIndex = 0
			rotation = .zero
			focusedSongID = newCollection.first?.id
		}
	}

	private func reanchor(to newIdx: Int, in newDeck: MusicItemCollection<Song>) {
		let count = newDeck.count
		guard count > 0 else { return }
		let cp = -rotation.degrees / DialView<Song>.stepVisual
		var diff = (Double(newIdx) - cp).truncatingRemainder(dividingBy: Double(count))
		let half = Double(count) / 2
		if diff > half { diff -= Double(count) }
		if diff < -half { diff += Double(count) }
		let newCp = cp + diff
		rotation = .degrees(-newCp * DialView<Song>.stepVisual)
		focusedIndex = newIdx
		focusedSongID = newDeck[newIdx].id
	}

	// MARK: - Shuffle

	/// Spins the wheel to a random nearby gem. When `autoplay` is on, also
	/// starts playback from the landed song; otherwise lands and waits.
	private func shuffle() async {
		let count = deck.count
		guard count > 0 else { return }

		let target: Int
		if count > 1 {
			let maxOffset = min(count - 1, DialTunables.maxShuffleJump)
			let magnitude = Int.random(in: 1 ... maxOffset)
			let direction = Bool.random() ? 1 : -1
			target = ((focusedIndex + magnitude * direction) % count + count) % count
		} else {
			target = 0
		}

		let destination = DialView<Song>.spinDestination(
			current: rotation,
			target: target,
			count: count
		)
		let distance = abs(destination.degrees - rotation.degrees) / DialView<Song>.stepVisual
		let duration = max(0.5, min(1.4, 0.35 + distance * 0.08))

		isSpinning = true
		withAnimation(.spring(duration: duration, bounce: 0.22)) {
			rotation = destination
		}
		try? await Task.sleep(for: .seconds(duration))
		isSpinning = false
		spinLandTick &+= 1

		let chosen = deck[target]
		focusedSongID = chosen.id
		rippleCounters[chosen.id, default: 0] &+= 1

		if autoplay {
			await play(from: chosen)
		}
	}

	// MARK: - Playback

	/// Seed the system queue with the picked song + the next 19 deck items so
	/// playback keeps flowing without us having to babysit `queue.insert` on
	/// every track end.
	private func play(from song: Song) async {
		let runway = Array(
			deck.drop(while: { $0.id != song.id }).prefix(20)
		)
		guard !runway.isEmpty else { return }
		do {
			SystemMusicPlayer.shared.queue = .init(for: runway)
			try await SystemMusicPlayer.shared.play()
			rippleCounters[song.id, default: 0] &+= 1
		} catch {
			print("Endless playback error: \(error)")
		}
	}

	private func open(_ song: Song) {
		guard let url = song.url else { return }
		openURL(url)
	}
}

#Preview {
	EndlessView()
}
