//
//  PlaylistsView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

enum PlaylistSortProperty {
	case lastPlayedDate, libraryAddedDate, name
}

/// Playlist-shuffle mode. The original Jukebox surface, now living inside a
/// tab. Mechanics (shuffle, reanchor, ripple) live in DialState; this view
/// owns playlist fetching, sort preference, and Apple-Music playback.
struct PlaylistsView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true
	@State private var sortBy: PlaylistSortProperty = .lastPlayedDate
	@State private var sortAscending = false

	@State private var playlists: MusicItemCollection<Playlist> = []
	@State private var dial = DialState()

	/// Defaults to true so the loading state is visible on the very first
	/// render, before `updatePlaylists` has had a chance to flip it on.
	@State private var isLoading: Bool = true

	private var focusedPlaylist: Playlist? {
		guard !playlists.isEmpty,
		      dial.focusedIndex >= 0,
		      dial.focusedIndex < playlists.count else { return nil }
		return playlists[dial.focusedIndex]
	}

	var body: some View {
		NavigationView {
			VStack(spacing: 0) {
				Spacer(minLength: 0)

				DialView(
					items: playlists,
					rotation: $dial.rotation,
					focusedIndex: $dial.focusedIndex,
					rippleCounters: dial.rippleCounters,
					placeholderSymbol: "music.note.list"
				) {
					if let playlist = focusedPlaylist {
						Task { await play(playlist) }
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.allowsHitTesting(!dial.isSpinning)

				if let playlist = focusedPlaylist, !dial.isSpinning {
					titleBlock(playlist)
				}

				Spacer(minLength: 0)
			}
			.animation(.easeInOut(duration: 0.25), value: focusedPlaylist?.id)
			.task(id: scenePhase) {
				if scenePhase == .active { await updatePlaylists() }
			}
			.refreshable { await updatePlaylists() }
			.safeAreaBar(edge: .bottom, alignment: .trailing) {
				PlaybackControls(
					disabled: dial.isSpinning || playlists.isEmpty,
					onPlay: { if let p = focusedPlaylist { await play(p) } },
					onShuffle: { await shuffle() }
				)
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) { SettingsMenu() }
				ToolbarItem(placement: .principal) { ToolbarLogo() }
				ToolbarItem(placement: .automatic) { sortMenu }
			}
			.sensoryFeedback(.impact(weight: .medium), trigger: dial.spinLandTick)
			.sensoryFeedback(.selection, trigger: dial.focusedIndex)
			.sensoryFeedback(.start, trigger: dial.playbackTick)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized {
					Task { await updatePlaylists() }
				}
			}
			.onChange(of: sortBy) { Task { await updatePlaylists() } }
			.onChange(of: sortAscending) { Task { await updatePlaylists() } }
			// Intentionally no refetch on play: re-sorting by last-played
			// mid-session pushes the just-played playlist to index 0, and
			// the reanchor that follows mutates the wheel rotation unanimated
			// — that was the "jerk at settle." The list refreshes on scene-
			// active, pull-to-refresh, and sort changes — none of which
			// happen while the user watches the wheel settle.
			.onChange(of: dial.focusedIndex) { _, newIdx in
				// Track focused id so we can re-anchor on collection updates
				// (e.g. when sort-by-last-played moves the just-played
				// playlist to the top). Skip during spin — focused changes
				// per frame and we set the id manually on land.
				guard !dial.isSpinning, newIdx >= 0, newIdx < playlists.count else { return }
				dial.focusedItemID = playlists[newIdx].id
			}
			.overlay {
				LibraryStateOverlay(
					isEmpty: playlists.isEmpty,
					isLoading: isLoading,
					loadingMessage: "Loading your playlists…",
					emptyMessage: "No Playlists",
					authMessage: "Jukebox needs access to your Apple Music library. Tap “Allow Access” to get started."
				)
			}
		}
	}

	private func titleBlock(_ playlist: Playlist) -> some View {
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
		.contentShape(.rect)
		.onTapGesture { open(playlist) }
		.transition(.blurReplace)
	}

	private var sortMenu: some View {
		Menu {
			Picker("Sort by", selection: $sortBy) {
				Text("Date Last Played").tag(PlaylistSortProperty.lastPlayedDate)
				Text("Date Added").tag(PlaylistSortProperty.libraryAddedDate)
				Text("Name").tag(PlaylistSortProperty.name)
			}

			Picker("Sort order", selection: $sortAscending) {
				Text("Ascending").tag(true)
				Text("Descending").tag(false)
			}
		} label: {
			Label("Sort Playlists", systemImage: "arrow.up.arrow.down.circle")
		}
		.disabled(dial.isSpinning)
	}

	// MARK: - Fetching

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
		// any remaining batches keep streaming in.
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

	private func applyPlaylists(_ new: MusicItemCollection<Playlist>) {
		let preservedID = dial.focusedItemID
		let newIdx = preservedID.flatMap { id in new.firstIndex(where: { $0.id == id }) }

		// Most foreground refetches return the same order the user already
		// sees — skip the animation in that case so a quiet tab-back doesn't
		// trigger a visible swap.
		let unchanged = playlists.count == new.count
			&& zip(playlists, new).allSatisfy { $0.id == $1.id }

		if unchanged {
			playlists = new
		} else {
			withAnimation(.smooth(duration: 0.5)) { playlists = new }
		}

		if new.isEmpty {
			dial.clear()
		} else if let newIdx {
			dial.reanchor(to: newIdx, newID: new[newIdx].id, count: new.count)
		} else if dial.focusedIndex >= new.count {
			dial.focusedIndex = 0
			dial.rotation = .zero
			dial.focusedItemID = new.first?.id
		}
	}

	// MARK: - Shuffle + play

	/// Spins the wheel to a random nearby playlist. When `autoplay` is on,
	/// plays it; otherwise lands and waits for the Play button.
	func shuffle() async {
		guard let target = DialMechanics.shuffleTarget(
			currentFocus: dial.focusedIndex,
			itemCount: playlists.count
		) else { return }

		let destination = DialMechanics.spinDestination(
			current: dial.rotation,
			target: target,
			count: playlists.count
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

		let chosen = playlists[target]
		dial.recordLanding(at: target, id: chosen.id)

		if autoplay { await play(chosen) }
	}

	func play(_ playlist: Playlist) async {
		guard let detailed = try? await playlist.with([.entries]),
		      let firstEntry = detailed.entries?.first else { return }
		do {
			SystemMusicPlayer.shared.queue = .init(playlist: detailed, startingAt: firstEntry)
			try await SystemMusicPlayer.shared.play()
			dial.markPlaying(id: playlist.id)
		} catch {
			print(error)
		}
	}

	private func open(_ playlist: Playlist) {
		guard let url = playlist.url
			?? URL(string: "music://music.apple.com/library/playlist/\(playlist.id)")
		else { return }
		openURL(url)
	}
}

#Preview {
	PlaylistsView()
}
