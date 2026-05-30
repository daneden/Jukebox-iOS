//
//  MusicPlayback.swift
//  Jukebox
//
//  Cross-platform playback verb. iOS drives `SystemMusicPlayer`; macOS lacks it,
//  so it routes through `AppleMusicScriptBridge` (AppleScript). Call sites stay
//  platform-agnostic.
//

import Foundation
import MusicKit
import OSLog

enum MusicPlayback {
	private static let log = Logger(subsystem: "me.daneden.Jukebox", category: "Playback")

	@discardableResult
	static func play(playlist: Playlist) async -> Bool {
		#if os(macOS)
			do {
				try await AppleMusicScriptBridge.play(playlist: playlist)
				return true
			} catch {
				log.error("play(playlist:) failed: \(error.localizedDescription, privacy: .public)")
				return false
			}
		#else
			AudioRouteSession.prepareForLongFormPlayback()
			guard let detailed = try? await playlist.with([.entries]),
			      let firstEntry = detailed.entries?.first else { return false }
			do {
				SystemMusicPlayer.shared.queue = .init(playlist: detailed, startingAt: firstEntry)
				try await SystemMusicPlayer.shared.play()
				return true
			} catch {
				log.error("play(playlist:) failed: \(error.localizedDescription, privacy: .public)")
				return false
			}
		#endif
	}

	/// Play a runway of songs. macOS stages them into a recycled `▶ Playback`
	/// user playlist (Music.app exposes no scriptable "Up Next") and plays that.
	@discardableResult
	static func play(songs: [Song]) async -> Bool {
		guard !songs.isEmpty else { return false }
		#if os(macOS)
			do {
				try await AppleMusicScriptBridge.play(songs: songs)
				return true
			} catch {
				log.error("play(songs:) failed: \(error.localizedDescription, privacy: .public)")
				return false
			}
		#else
			AudioRouteSession.prepareForLongFormPlayback()
			do {
				SystemMusicPlayer.shared.queue = .init(for: songs)
				try await SystemMusicPlayer.shared.play()
				return true
			} catch {
				log.error("play(songs:) failed: \(error.localizedDescription, privacy: .public)")
				return false
			}
		#endif
	}

	/// Create a new library playlist from the given songs. macOS drives Music.app
	/// via AppleScript since MusicKit on macOS ships no library-mutation API.
	/// Throws on failure so callers can surface a precise error.
	@discardableResult
	static func save(songs: [Song], asPlaylistNamed name: String, description: String) async throws -> Int {
		guard !songs.isEmpty else { return 0 }
		#if os(macOS)
			return try await AppleMusicScriptBridge.save(
				songs: songs,
				asPlaylistNamed: name,
				description: description
			)
		#else
			_ = try await MusicLibrary.shared.createPlaylist(
				name: name,
				description: description,
				items: songs
			)
			return songs.count
		#endif
	}
}
