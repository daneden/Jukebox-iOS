//
//  ControlSupport.swift
//  Jukebox
//
//  Intents behind the Control Center controls. Per Apple's controls model, a
//  control button's `perform()` runs in the *widget extension's* process (the
//  app is only launched for an `OpenIntent`). So these run without foregrounding
//  the app — and must be self-contained: MusicKit + Foundation only, no app-only
//  builders (`GemDeckBuilder`, `IntentActions`), which the extension can't link.
//
//  TARGET MEMBERSHIP: this file belongs to BOTH the `Jukebox` app and the
//  `WidgetsExtension` target (the extension references these types for the
//  control buttons). They're `isDiscoverable = false` so they don't clutter
//  Shortcuts — the rich, parameterized intents in the other files are the
//  Shortcuts surface.
//

import AppIntents
import Foundation
import MusicKit

struct PlayRandomPlaylistControlIntent: AppIntent {
	static var title: LocalizedStringResource = "Play Random Playlist"
	static var isDiscoverable: Bool {
		false
	}

	static var supportedModes: IntentModes {
		.background
	}

	func perform() async throws -> some IntentResult {
		#if os(iOS)
			let request = MusicLibraryRequest<Playlist>()
			if let response = try? await request.response(),
			   let playlist = response.items.randomElement(),
			   let detailed = try? await playlist.with([.entries]),
			   let first = detailed.entries?.first
			{
				SystemMusicPlayer.shared.queue = .init(playlist: detailed, startingAt: first)
				try? await SystemMusicPlayer.shared.play()
			}
		#endif
		return .result()
	}
}

struct MakeGemsControlIntent: AppIntent {
	static var title: LocalizedStringResource = "Make a Playlist"
	static var isDiscoverable: Bool {
		false
	}

	static var supportedModes: IntentModes {
		.background
	}

	func perform() async throws -> some IntentResult {
		#if os(iOS)
			guard let runway = try? await Self.quickGemsRunway(), let seed = runway.first else {
				return .result()
			}
			SystemMusicPlayer.shared.queue = .init(for: runway)
			try? await SystemMusicPlayer.shared.play()
			// Parity with the app + Siri: log to (shared) History and remember
			// the seed so the next run steers away from it.
			AppGroupStore.lastSeedArtist = seed.artistName
			await HistoryStore.shared.record(
				name: PlaylistNamer.suggestedName(seedArtist: seed.artistName),
				seed: SongSnapshot(song: seed),
				runway: runway.map(SongSnapshot.init(song:))
			)
		#endif
		return .result()
	}

	#if os(iOS)
		/// A control-extension–sized gems pick that matches the app on the
		/// behaviours that matter: it reads the shared `ExclusionStore` (removed
		/// items never resurface), scores with the real `GemScorer` (using the
		/// shared History recency), caps per artist/album so a prolific artist
		/// can't dominate, steers away from the previous run's artist, and
		/// shuffles for tap-to-tap variety. It omits only the embedding-based
		/// similarity walk, which needs the full app.
		private static func quickGemsRunway(limit: Int = 20) async throws -> [Song] {
			var topReq = MusicLibraryRequest<Song>()
			topReq.sort(by: \.playCount, ascending: false)
			topReq.limit = 400
			var oldReq = MusicLibraryRequest<Song>()
			oldReq.sort(by: \.libraryAddedDate, ascending: true)
			oldReq.limit = 400
			// Immutable snapshots: `async let` mustn't capture a mutable var.
			let topPlayed = topReq
			let oldest = oldReq

			async let topResponse = topPlayed.response()
			async let oldestResponse = oldest.response()
			let pool = try await Array(topResponse.items) + Array(oldestResponse.items)

			// Shared app data via the App Group.
			let exclusions = await ExclusionStore.shared.exclusions()
			let recentPlays = await HistoryStore.shared.recentPlays(within: 14 * 86400)

			var seen = Set<MusicItemID>()
			let deduped = pool.filter { seen.insert($0.id).inserted && !exclusions.excludes(song: $0) }
			let ranked = GemScorer(recentPlays: recentPlays).scoreAndRank(deduped).map(\.song)

			// Per-artist (≤3) / per-album (≤2) caps over the scored head.
			var perArtist: [String: Int] = [:]
			var perAlbum: [String: Int] = [:]
			var head: [Song] = []
			for song in ranked {
				if perArtist[song.artistName, default: 0] >= 3 { continue }
				let album = song.albumTitle ?? ""
				if !album.isEmpty, perAlbum[album, default: 0] >= 2 { continue }
				head.append(song)
				perArtist[song.artistName, default: 0] += 1
				if !album.isEmpty { perAlbum[album, default: 0] += 1 }
				if head.count >= 80 { break }
			}

			var shuffled = head.shuffled()
			// Bias the FIRST pick away from the previous run's artist.
			if let avoid = AppGroupStore.lastSeedArtist, shuffled.first?.artistName == avoid,
			   let other = shuffled.firstIndex(where: { $0.artistName != avoid })
			{
				shuffled.swapAt(0, other)
			}
			return Array(shuffled.prefix(limit))
		}
	#endif
}
