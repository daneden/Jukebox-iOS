//
//  MusicKitWarmup.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//

import MusicKit

/// Process-wide gate to serialise the very first `MusicLibraryRequest`
/// after launch. On iOS 26, `musicd` / `itunescloudd` can wedge if two
/// or more library requests fan out in parallel before account and
/// subscription resolution finishes — symptoms cluster as a hung
/// `response()`, stuck `library://` artwork loads, and back-pressure
/// into shared system services (which has knocked over an unrelated
/// SwiftData sheet in `HistoryView` in practice). Once a single request
/// has completed, the daemon is initialised and parallels are fine.
///
/// Surfaces that initiate library work on app launch (the Songs deck
/// builder, the Playlists list, anywhere else that fires
/// `MusicLibraryRequest`) `await` the same probe before fanning out.
/// The probe runs once per process; subsequent calls return
/// immediately.
enum MusicKitWarmup {
	private static let task: Task<Void, Never> = Task {
		// Two serial probes — Songs and Playlists — because the daemon
		// appears to warm per entity path. A Songs-only probe was
		// enough to fix the original cold-launch cluster (only Songs
		// fetches were in flight then), but the tab-switch-during-load
		// case stacks a Playlists fetch on top of Songs fan-out, and
		// that path is still cold without its own probe. Confirmed
		// empirically: launching directly on the Playlists tab — which
		// fires one serial Playlists request as the very first
		// MusicKit op — avoids the bug entirely.
		var songProbe = MusicLibraryRequest<Song>()
		songProbe.limit = 1
		_ = try? await songProbe.response()

		var playlistProbe = MusicLibraryRequest<Playlist>()
		playlistProbe.limit = 1
		_ = try? await playlistProbe.response()
	}

	/// Suspend until the first `MusicLibraryRequest` of this process has
	/// completed. Safe to call from many concurrent contexts; they all
	/// await the same singleton task.
	static func waitUntilReady() async {
		await task.value
	}
}
