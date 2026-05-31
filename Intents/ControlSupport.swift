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
			if let runway = try? await Self.quickGemsRunway(), !runway.isEmpty {
				SystemMusicPlayer.shared.queue = .init(for: runway)
				try? await SystemMusicPlayer.shared.play()
			}
		#endif
		return .result()
	}

	#if os(iOS)
		/// A deliberately-light gems pick that fits a control extension's memory
		/// budget: two bounded library pools, a simple nostalgia score, a shuffled
		/// runway. This is NOT the in-app deck — no embeddings, similarity walk,
		/// energy/decade filters, or exclusions (those need the app). For a
		/// one-tap Control Center action, "heavily-played but long-dormant" is a
		/// good-enough surprise.
		private static func quickGemsRunway(limit: Int = 20) async throws -> [Song] {
			var topReq = MusicLibraryRequest<Song>()
			topReq.sort(by: \.playCount, ascending: false)
			topReq.limit = 250
			var oldReq = MusicLibraryRequest<Song>()
			oldReq.sort(by: \.libraryAddedDate, ascending: true)
			oldReq.limit = 250
			// Immutable snapshots: `async let` mustn't capture a mutable var
			// (an error under Swift 6).
			let topPlayed = topReq
			let oldest = oldReq

			async let topResponse = topPlayed.response()
			async let oldestResponse = oldest.response()
			let pool = try await Array(topResponse.items) + Array(oldestResponse.items)

			var seen = Set<MusicItemID>()
			let now = Date()
			let scored = pool
				.filter { seen.insert($0.id).inserted && $0.playParameters != nil }
				.map { song -> (song: Song, score: Double) in
					let plays = Double(song.playCount ?? 0)
					let dormantDays = song.lastPlayedDate.map { now.timeIntervalSince($0) / 86400 } ?? 365
					return (song, log(plays + 1) * max(0, dormantDays))
				}
				.sorted { $0.score > $1.score }
				.map(\.song)

			// Shuffle within the top so each tap differs, then take a runway.
			return Array(Array(scored.prefix(80)).shuffled().prefix(limit))
		}
	#endif
}
