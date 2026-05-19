//
//  ContentView.swift
//  Jukebox
//
//  Created by Daniel Eden on 27/09/2021.
//

import MediaPlayer
import MusicKit
import SwiftUI

enum PlaylistSortProperty {
	case lastPlayedDate, libraryAddedDate, name
}

struct ContentView: View {
	@Environment(\.colorScheme) private var colorScheme
	@Namespace private var namespace
	@Environment(\.scenePhase) private var scenePhase
	@State private var sortBy: PlaylistSortProperty = .lastPlayedDate
	@State private var sortAscending = false

	@State private var playlists: MusicItemCollection<Playlist> = []
	@State private var chosenPlaylist: Playlist?

	@State private var rotation: Angle = .zero
	@State private var focusedIndex: Int = 0
	@State private var focusedPlaylistID: MusicItemID?
	@State private var spinLandTick: Int = 0
	@State private var isSpinning: Bool = false
	/// Per-playlist counter incremented when the shuffle button settles on
	/// that playlist. Used as the per-cover RippleEffect trigger — only the
	/// landed cover's entry changes, so only that cover ripples (a single
	/// shared trigger would fire the previously-landed cover too).
	@State private var rippleCounters: [MusicItemID: Int] = [:]
	/// Defaults to true so the loading state is visible on the very first
	/// render, before `updatePlaylists` has had a chance to flip it on.
	@State private var isLoading: Bool = true

	private var focusedPlaylist: Playlist? {
		guard !playlists.isEmpty,
		      focusedIndex >= 0,
		      focusedIndex < playlists.count else { return nil }
		return playlists[focusedIndex]
	}

	var body: some View {
		NavigationView {
			VStack(spacing: 0) {
				Spacer(minLength: 0)

				PlaylistDialView(
					playlists: playlists,
					rotation: $rotation,
					focusedIndex: $focusedIndex,
					rippleCounters: rippleCounters
				) {
					if let playlist = focusedPlaylist {
						Task { await play(playlist) }
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.allowsHitTesting(!isSpinning)

				if let playlist = focusedPlaylist, !isSpinning {
					VStack(spacing: 4) {
						Text(playlist.name)
							.font(.title2)
							.fontWeight(.semibold)
							.multilineTextAlignment(.center)
							.lineLimit(2)

						Text(playlist.curatorName ?? "")
							.font(.subheadline)
							.foregroundStyle(.secondary)
					}
					.id(playlist.id)
					.contentTransition(.numericText())
					.padding(.horizontal, 24)
					.padding(.bottom, 24)
					.transition(.blurReplace)
				}

				Spacer(minLength: 0)
			}
			.animation(.easeInOut(duration: 0.25), value: focusedPlaylist?.id)
			.task(id: scenePhase) {
				switch scenePhase {
				case .active: await updatePlaylists()
				default: break
				}
			}
			.refreshable {
				await updatePlaylists()
			}
			.safeAreaBar(edge: .bottom, alignment: .trailing) {
				GlassEffectContainer(spacing: 8) {
					HStack(spacing: 8) {
						NowPlayingView(playlist: $chosenPlaylist)
							.glassEffectID("toolbar", in: namespace)

						AsyncButton {
							await playRandom()
						} label: {
							Label("Play Random Playlist", systemImage: "shuffle")
								.foregroundStyle(colorScheme == .dark ? .black : .white)
						}
						.fontWeight(.bold)
						.buttonStyle(.glassProminent)
						.buttonBorderShape(.circle)
						.controlSize(.extraLarge)
						.glassEffectID("toolbar", in: namespace)
						.disabled(isSpinning || playlists.isEmpty)
					}
					.frame(height: 64)
				}
				.scenePadding(.horizontal)
				.animation(.default, value: chosenPlaylist)
			}
			.toolbar {
				ToolbarItem(placement: .principal) {
					Image(.playback)
						.resizable()
						.aspectRatio(contentMode: .fit)
						.frame(height: 64)
						.foregroundStyle(.primary)
				}
				ToolbarItem(placement: .automatic) {
					Menu {
						Picker("Sort by", selection: $sortBy) {
							Text("Date Last Played")
								.tag(PlaylistSortProperty.lastPlayedDate)

							Text("Date Added")
								.tag(PlaylistSortProperty.libraryAddedDate)

							Text("Name")
								.tag(PlaylistSortProperty.name)
						}

						Picker("Sort order", selection: $sortAscending) {
							Text("Ascending")
								.tag(true)
							Text("Descending")
								.tag(false)
						}
					} label: {
						Label("Sort Playlists", systemImage: "arrow.up.arrow.down.circle")
					}
					.disabled(isSpinning)
				}
			}
			.sensoryFeedback(.impact(weight: .medium), trigger: spinLandTick)
			.sensoryFeedback(.selection, trigger: focusedIndex)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized {
					Task { await updatePlaylists() }
				}
			}
			.onChange(of: sortBy) {
				Task { await updatePlaylists() }
			}
			.onChange(of: sortAscending) {
				Task { await updatePlaylists() }
			}
			// Intentionally no `.onChange(of: chosenPlaylist)`: refetching mid-
			// session pushes the just-played playlist to index 0 under sort-by-
			// last-played, and `applyPlaylists` → `reanchor` then mutates the
			// wheel rotation by however many detents the playlist jumped. That
			// unanimated rotation change was the "jerk at settle." The list
			// refreshes naturally on scene-active, pull-to-refresh, and sort
			// changes — none of which happen while the user is watching the
			// wheel finish settling.
			.onChange(of: focusedIndex) { _, newIdx in
				// Track which playlist (by id) is currently focused, so we can
				// re-anchor the wheel to the same playlist after the library
				// reorders (e.g. when sort-by-last-played moves the just-played
				// playlist to the top). Skip during spin — focused changes per
				// frame during shuffle and we set the id manually at land time.
				guard !isSpinning, newIdx >= 0, newIdx < playlists.count else { return }
				focusedPlaylistID = playlists[newIdx].id
			}
			.overlay {
				switch MusicAuthorization.currentStatus {
				case .notDetermined:
					VStack {
						Spacer()
						Text("Get Started")
							.font(.headline)
						Text("Jukebox needs access to your Apple Music library. Tap “Allow Access” to get started.")
						Button("Allow Access") {
							Task {
								await MusicAuthorization.request()
							}
						}
						.buttonStyle(.borderedProminent)
						Spacer()
					}
					.scenePadding()
				case .authorized:
					if playlists.isEmpty {
						VStack(spacing: 12) {
							Spacer()
							if isLoading {
								ProgressView()
									.controlSize(.large)
								Text("Loading your playlists…")
									.font(.subheadline)
									.foregroundStyle(.secondary)
							} else {
								Text("No Playlists")
									.foregroundStyle(.secondary)
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

	func updatePlaylists() async {
		isLoading = true
		defer { isLoading = false }

		var request = MusicLibraryRequest<Playlist>()
		switch sortBy {
		case .lastPlayedDate:
			request.sort(by: \.lastPlayedDate, ascending: sortAscending)
		case .libraryAddedDate:
			request.sort(by: \.libraryAddedDate, ascending: sortAscending)
		case .name:
			request.sort(by: \.name, ascending: sortAscending)
		}

		guard let response = try? await request.response() else { return }

		// Show the first batch immediately so the dial is interactive while
		// any remaining batches keep streaming in. This is the main perceived
		// speedup — going from one library-wide round-trip to one batch-sized
		// one before the user sees anything.
		var accumulated = response.items
		applyPlaylists(accumulated)

		var latest = response.items
		while latest.hasNextBatch {
			guard let next = try? await latest.nextBatch() else { break }
			accumulated += next
			latest = next
			applyPlaylists(accumulated)
		}
	}

	/// Commits a batch of playlists to state and re-anchors focus by id so the
	/// dial doesn't snap to a different playlist mid-load.
	private func applyPlaylists(_ new: MusicItemCollection<Playlist>) {
		let preservedID: MusicItemID? = focusedPlaylistID ?? chosenPlaylist?.id
		let newIdx: Int? = preservedID.flatMap { id in
			new.firstIndex(where: { $0.id == id })
		}

		withAnimation {
			self.playlists = new
		}

		if new.isEmpty {
			focusedIndex = 0
			rotation = .zero
			focusedPlaylistID = nil
		} else if let newIdx {
			reanchor(to: newIdx, in: new)
		} else if focusedIndex >= new.count {
			focusedIndex = 0
			rotation = .zero
			focusedPlaylistID = new.first?.id
		}
	}

	/// Shift `rotation` to the value congruent (mod count) that's closest to the
	/// current position. Keeps the same playlist centered after a list reorder
	/// without teleporting the wheel back to the modular-zero representative.
	private func reanchor(to newIdx: Int, in newPlaylists: MusicItemCollection<Playlist>) {
		let count = newPlaylists.count
		guard count > 0 else { return }
		let cp = -rotation.degrees / PlaylistDialView.stepVisual
		var diff = (Double(newIdx) - cp).truncatingRemainder(dividingBy: Double(count))
		let half = Double(count) / 2
		if diff > half { diff -= Double(count) }
		if diff < -half { diff += Double(count) }
		let newCp = cp + diff
		rotation = .degrees(-newCp * PlaylistDialView.stepVisual)
		focusedIndex = newIdx
		focusedPlaylistID = newPlaylists[newIdx].id
	}

	func playRandom() async {
		let count = playlists.count
		guard count > 0 else { return }

		// Pick a random target within `maxShuffleJump` of the current focus,
		// in either direction. Keeps spins bounded so we don't load half the
		// library's artwork to cross from one end to the other.
		let target: Int
		if count > 1 {
			let maxOffset = min(count - 1, DialTunables.maxShuffleJump)
			let magnitude = Int.random(in: 1 ... maxOffset)
			let direction = Bool.random() ? 1 : -1
			target = ((focusedIndex + magnitude * direction) % count + count) % count
		} else {
			target = 0
		}

		let destination = PlaylistDialView.spinDestination(
			current: rotation,
			target: target,
			count: count
		)

		// Scale spin duration to actual angular distance — short hops feel
		// like a flick; longer trips get a touch more time to ease out.
		let distance = abs(destination.degrees - rotation.degrees) / PlaylistDialView.stepVisual
		let duration = max(0.5, min(1.4, 0.35 + distance * 0.08))

		isSpinning = true
		// SwiftUI's Animatable on DialContent fans the body re-run out per
		// frame, so covers actually transit the visible window during the
		// animation and the per-detent haptic fires inside the setter.
		withAnimation(.spring(duration: duration, bounce: 0.22)) {
			rotation = destination
		}
		try? await Task.sleep(for: .seconds(duration))
		isSpinning = false
		spinLandTick &+= 1

		let chosen = playlists[target]
		focusedPlaylistID = chosen.id
		rippleCounters[chosen.id, default: 0] &+= 1
		if let detailedPlaylist = try? await chosen.with([.entries]) {
			chosenPlaylist = detailedPlaylist
			await playPlaylist(playlist: detailedPlaylist)
		}
	}

	func play(_ playlist: Playlist) async {
		if let detailedPlaylist = try? await playlist.with([.entries]) {
			chosenPlaylist = detailedPlaylist
			await playPlaylist(playlist: detailedPlaylist)
		}
	}

	func playPlaylist(playlist: Playlist) async {
		do {
			guard let firstEntry = playlist.entries?.first else {
				return
			}
			SystemMusicPlayer.shared.queue = .init(playlist: playlist, startingAt: firstEntry)
			try await SystemMusicPlayer.shared.play()
		} catch {
			print(error)
		}
	}
}

#Preview {
	ContentView()
}
