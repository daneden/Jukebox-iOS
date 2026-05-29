//
//  MusicKitWarmup.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/05/2026.
//

import MusicKit

/// Process-wide gate serialising the first `MusicLibraryRequest` after launch.
/// On iOS 26, `musicd` / `itunescloudd` can wedge if two or more library
/// requests fan out in parallel before account/subscription resolution finishes
/// (hung `response()`, stuck `library://` artwork, back-pressure that has
/// knocked over an unrelated SwiftData sheet in `HistoryView`). Once one request
/// completes the daemon is initialised and parallels are fine. Launch surfaces
/// `await` this probe before fanning out; it runs once per process.
enum MusicKitWarmup {
	private static let task: Task<Void, Never> = Task {
		// Two serial probes because the daemon warms per entity path. A Songs-only
		// probe fixed the original cold-launch cluster, but tab-switch-during-load
		// stacks a Playlists fetch on Songs fan-out — that path is cold without its
		// own probe.
		var songProbe = MusicLibraryRequest<Song>()
		songProbe.limit = 1
		_ = try? await songProbe.response()

		var playlistProbe = MusicLibraryRequest<Playlist>()
		playlistProbe.limit = 1
		_ = try? await playlistProbe.response()
	}

	/// Suspend until the first `MusicLibraryRequest` of this process has
	/// completed. Safe to call from many concurrent contexts.
	static func waitUntilReady() async {
		await task.value
	}
}
