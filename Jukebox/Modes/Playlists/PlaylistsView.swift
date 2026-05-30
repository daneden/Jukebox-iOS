//
//  PlaylistsView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Playlist-shuffle mode. Mechanics (shuffle, reanchor, ripple) live in
/// DialState; this view owns playlist fetching and Apple-Music playback.
struct PlaylistsView: View {
	@Environment(\.scenePhase) private var scenePhase
	@Environment(\.openURL) private var openURL

	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true

	@State private var playlists: MusicItemCollection<Playlist> = []
	@State private var dial = DialState()

	/// Defaults to true so the loading state shows on first render, before
	/// `updatePlaylists` flips it.
	@State private var isLoading: Bool = true

	/// Playlists flagged ineligible via the context menu. Applied in
	/// `applyPlaylists` so removed playlists never re-enter across refetches.
	@State private var blockedPlaylistIDs: Set<String> = []

	private var focusedPlaylist: Playlist? {
		guard !playlists.isEmpty,
		      dial.focusedIndex >= 0,
		      dial.focusedIndex < playlists.count else { return nil }
		return playlists[dial.focusedIndex]
	}

	/// `focusedPlaylist` only while the dial is at rest, so the title block
	/// empties out during shuffle instead of disappearing (which would
	/// shift the dial up and back).
	private var settledPlaylist: Playlist? {
		dial.isSpinning ? nil : focusedPlaylist
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				Spacer(minLength: 0)

				DialView(
					items: playlists,
					rotation: $dial.rotation,
					focusedIndex: $dial.focusedIndex,
					rippleCounters: dial.rippleCounters,
					placeholderSymbol: "music.note.list",
					contextMenu: { playlist in playlistContextMenu(for: playlist) }
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
				// Scoped to the title block on purpose: on the parent VStack
				// it would also catch `DialContent`'s `animatableData:
				// rotation` and visibly animate the dial.
				.animation(.easeInOut(duration: 0.25), value: settledPlaylist?.id)

				Spacer(minLength: 0)
			}
			.task(id: scenePhase) {
				if scenePhase == .active { await updatePlaylists() }
			}
			.refreshable { await updatePlaylists() }
			.tabHeader(tip: PlaylistsTip())
			.safeAreaBar(edge: .bottom, alignment: .trailing) {
				PlaybackControls(
					disabled: dial.isSpinning || playlists.isEmpty,
					onPlay: { if let p = focusedPlaylist { await play(p) } },
					onShuffle: { await shuffle() }
				)
			}
			.primaryToolbar()
			.sensoryFeedback(.impact(weight: .medium), trigger: dial.spinLandTick)
			// Trigger on id, not index: a reanchor changes the index while
			// keeping the same song focused — no haptic for that.
			.sensoryFeedback(.selection, trigger: dial.focusedItemID)
			.sensoryFeedback(.start, trigger: dial.playbackTick)
			.onChange(of: MusicAuthorization.currentStatus) { _, newValue in
				if newValue == .authorized {
					Task { await updatePlaylists() }
				}
			}
			// No refetch on play: re-sorting by last-played pushes the
			// just-played playlist to index 0, and the reanchor mutates
			// rotation unanimated — that was the "jerk at settle." Refresh
			// happens on scene-active / pull-to-refresh / sort change, never
			// mid-settle.
			.onChange(of: dial.focusedIndex) { _, newIdx in
				// Track focused id to re-anchor on collection updates. Skip
				// during spin — focused changes per frame and we set the id
				// manually on land.
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

		// Pre-position before the first batch: mutating rotation in
		// applyPlaylists flushes in the same render pass as the playlists
		// mutation and visibly spins the dial. Count is unknown yet, so
		// pick from a large range and let applyPlaylists modular-wrap it.
		// Guard so resume/refresh don't randomize.
		if dial.focusedItemID == nil {
			let offset = Int.random(in: 0 ..< 10000)
			dial.rotation = .degrees(-Double(offset) * DialTunables.stepVisual)
		}

		// Hold behind the MusicKit probe: issuing a request in parallel
		// with the Songs deck fan-out before `musicd` warms can wedge the
		// daemon.
		await MusicKitWarmup.waitUntilReady()

		blockedPlaylistIDs = await ExclusionStore.shared.blockedPlaylistIDs()

		var request = MusicLibraryRequest<Playlist>()
		#if os(iOS)
			// Sorting by `.lastPlayedDate` crashes the macOS MusicKit
			// resolver (`unrecognized selector` — no bridged sort descriptor
			// there). macOS falls back to default library order.
			request.sort(by: \.lastPlayedDate, ascending: false)
		#endif

		guard let response = try? await request.response() else { return }

		// Show the first batch immediately so the dial is interactive while
		// remaining batches stream in.
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

	private func applyPlaylists(_ raw: MusicItemCollection<Playlist>) {
		let filtered = blockedPlaylistIDs.isEmpty
			? Array(raw)
			: raw.filter { !blockedPlaylistIDs.contains($0.id.rawValue) }

		// Keep the order already on the dial and append newly-seen playlists
		// (themselves shuffled). On cold start nothing is on the dial, so the
		// whole set is "new" and gets shuffled — each launch explores a fresh
		// random sequence instead of last-played order. Preserving the
		// existing order is what stops streaming batches and resume refetches
		// from snapping the dial back to last-played mid-session.
		let ordered: [Playlist]
		if playlists.isEmpty {
			ordered = filtered.shuffled()
		} else {
			let byID = Dictionary(filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
			let known = Set(playlists.map(\.id))
			ordered = playlists.compactMap { byID[$0.id] }
				+ filtered.filter { !known.contains($0.id) }.shuffled()
		}
		let new = MusicItemCollection(ordered)

		let preservedID = dial.focusedItemID
		let newIdx = preservedID.flatMap { id in new.firstIndex(where: { $0.id == id }) }

		// Animate only on real reorders. Skip when the prefix is unchanged
		// (no change, or pure tail append) — every nextBatch() appends, and
		// animating each one spring-thrashes the dial's wrap edge.
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
			// Cold launch: derive the landing index from the pre-positioned
			// rotation (modular-wrapped to the now-known count) so the dial
			// renders in place without animating from 0.
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

	// MARK: - Removal

	/// Per-cover context menu — flags the playlist ineligible (via
	/// `ExclusionStore`) and drops it from the live collection.
	private func playlistContextMenu(for playlist: Playlist) -> some View {
		Button(role: .destructive) {
			Task { await removePlaylist(playlist) }
		} label: {
			Label("Remove Playlist", systemImage: "minus.circle")
		}
	}

	private func removePlaylist(_ playlist: Playlist) async {
		blockedPlaylistIDs.insert(playlist.id.rawValue)

		let remaining = playlists.filter { $0.id != playlist.id }
		if remaining.count != playlists.count {
			let preservedID = dial.focusedItemID
			let oldIdx = dial.focusedIndex
			let newCollection = MusicItemCollection<Playlist>(remaining)
			withAnimation(.smooth(duration: 0.4)) { playlists = newCollection }
			if newCollection.isEmpty {
				dial.clear()
			} else if let pid = preservedID, let idx = newCollection.firstIndex(where: { $0.id == pid }) {
				dial.reanchor(to: idx, newID: newCollection[idx].id, count: newCollection.count)
			} else {
				let target = max(0, min(oldIdx, newCollection.count - 1))
				dial.reanchor(to: target, newID: newCollection[target].id, count: newCollection.count)
			}
		}

		await ExclusionStore.shared.blockPlaylist(id: playlist.id.rawValue, label: playlist.name)
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

		// Detached so the Shuffle spinner ends with the visual landing —
		// playback startup can take seconds and shouldn't outlive the spin.
		if autoplay { Task { await play(chosen) } }
	}

	func play(_ playlist: Playlist) async {
		if await MusicPlayback.play(playlist: playlist) {
			dial.markPlaying(id: playlist.id)
		}
	}

	private func open(_ playlist: Playlist) {
		// Library-only playlists have a nil `Playlist.url`; the iOS Music
		// library deep-link handles them by id. The same URL errors on
		// macOS Music, so the fallback is iOS-only (macOS library-only
		// playlists no-op).
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
