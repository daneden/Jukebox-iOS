//
//  PlaylistsView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Playlist-shuffle mode. The original Playback surface, now living inside a
/// tab. Mechanics (shuffle, reanchor, ripple) live in DialState; this view
/// owns playlist fetching and Apple-Music playback.
struct PlaylistsView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true

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

	/// `focusedPlaylist` only while the dial is at rest. Used by the title
	/// block so the text empties out during shuffle instead of disappearing,
	/// which would shift the dial up and back.
	private var settledPlaylist: Playlist? {
		dial.isSpinning ? nil : focusedPlaylist
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				#if os(macOS)
					ToolbarLogo()
						.padding(.top, 8)
				#endif

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

				TitleBlock(
					title: settledPlaylist?.name ?? "",
					subtitle: settledPlaylist?.curatorName ?? "",
					onTap: { if let playlist = settledPlaylist { open(playlist) } }
				)
				// Scoped to the title block subtree on purpose — applying
				// this on the parent VStack also catches `DialContent`'s
				// `animatableData: rotation`, so any case where the rotation
				// changes in the same body re-evaluation as `focusedPlaylist?.id`
				// would visibly animate the dial.
				.animation(.easeInOut(duration: 0.25), value: settledPlaylist?.id)

				Spacer(minLength: 0)
			}
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
				ToolbarItem(placement: .navigation) { SettingsMenu() }
				#if os(iOS)
					// macOS renders the wordmark inline above the dial (the
					// title-bar `.principal` slot competes with the window
					// chrome and looks out of place there).
					ToolbarItem(placement: .principal) { ToolbarLogo() }
				#endif
			}
			.sensoryFeedback(.impact(weight: .medium), trigger: dial.spinLandTick)
			// Trigger on the focused song's *id*, not its index — a
			// reanchor (e.g. partial → final deck swap during streaming)
			// changes the index while keeping the same song focused, and
			// the user shouldn't feel a haptic for that.
			.sensoryFeedback(.selection, trigger: dial.focusedItemID)
			.sensoryFeedback(.start, trigger: dial.playbackTick)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized {
					Task { await updatePlaylists() }
				}
			}
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
					emptyMessage: "No playlists"
				)
			}
		}
	}

	// MARK: - Fetching

	func updatePlaylists() async {
		isLoading = true
		defer { isLoading = false }

		// Pre-position the dial before the first batch arrives. Same
		// rationale as SongsView.buildDeck: mutating rotation in
		// applyPlaylists (when items first land) flushes in the same
		// SwiftUI render pass as the playlists mutation and visibly spins
		// the dial. We don't know the eventual count yet, so pick from a
		// large range and let `applyPlaylists` modular-wrap it to a valid
		// index when the batch arrives. Guard so resume/refresh don't
		// randomize.
		if dial.focusedItemID == nil {
			let offset = Int.random(in: 0 ..< 10000)
			dial.rotation = .degrees(-Double(offset) * DialTunables.stepVisual)
		}

		var request = MusicLibraryRequest<Playlist>()
		#if os(iOS)
			// `.lastPlayedDate` as a sort keypath crashes the macOS MusicKit
			// resolver with `-[NSSortDescriptor keyPath]: unrecognized selector`
			// — the property is declared in the cross-platform protocol but
			// has no NSObject-bridged sort descriptor on macOS. Use the
			// default library order (library add date) there.
			request.sort(by: \.lastPlayedDate, ascending: false)
		#endif

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

		// Animate only when items actually reordered (background → foreground
		// after playing something, deletes, etc.). Skip animation when:
		//   - The new collection has the same prefix as the old — covers
		//     either no change (counts equal) or pure append at the tail
		//     (counts grew). Append happens on every nextBatch() during
		//     initial streaming; animating each batch spring-thrashes the
		//     wrap-around edge of the dial for nothing.
		//   - The dial is empty (no prior visual state to lift from).
		let prefixUnchanged = new.count >= playlists.count
			&& zip(playlists, new.prefix(playlists.count)).allSatisfy { $0.id == $1.id }

		if prefixUnchanged {
			playlists = new
		} else {
			withAnimation(.smooth(duration: 0.5)) { playlists = new }
		}

		if new.isEmpty {
			dial.clear()
		} else if let newIdx {
			dial.reanchor(to: newIdx, newID: new[newIdx].id, count: new.count)
		} else if preservedID == nil {
			// Cold launch. Rotation was pre-positioned in updatePlaylists
			// before this fired — derive the landing index from it (modular
			// wrap across the now-known count) so the dial renders in its
			// final position without animating from 0.
			let continuousPos = -dial.rotation.degrees / DialTunables.stepVisual
			let raw = Int(continuousPos.rounded())
			let landingIdx = ((raw % new.count) + new.count) % new.count
			dial.focusedIndex = landingIdx
			dial.focusedItemID = new[landingIdx].id
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

		// Detached so the Shuffle button's busy state ends with the visual
		// landing. `playlist.with([.entries])` + `MusicPlayback.play()` can
		// take many seconds (network fetch + player startup) and we don't
		// want the spinner to outlive the spin the user can already see.
		if autoplay { Task { await play(chosen) } }
	}

	func play(_ playlist: Playlist) async {
		if await MusicPlayback.play(playlist: playlist) {
			dial.markPlaying(id: playlist.id)
		}
	}

	private func open(_ playlist: Playlist) {
		// Library-only playlists (user-created, never shared) have a nil
		// `Playlist.url`. The iOS Music app's library deep-link scheme
		// handles them by MusicKit id. The same URL form errors on macOS
		// Music ("Sorry, something went wrong"), so the fallback is
		// iOS-only — on macOS, catalog playlists still open via
		// `playlist.url`, library-only ones no-op.
		var url: URL? = playlist.url
		#if os(iOS)
			if url == nil {
				url = URL(string: "music://music.apple.com/library/playlist/\(playlist.id)")
			}
		#endif
		guard let url else { return }
		openURL(url)
	}
}

#Preview {
	PlaylistsView()
}
