//
//  MusicPlayback.swift
//  Jukebox
//
//  Cross-platform playback verb. On iOS we drive `SystemMusicPlayer` so
//  Music.app's queue picks up what we play; on macOS that player doesn't
//  exist, so we route through `AppleMusicScriptBridge` which controls
//  Music.app via AppleScript instead. Call sites stay platform-agnostic.
//

import Foundation
import MusicKit

enum MusicPlayback {
	@discardableResult
	static func play(playlist: Playlist) async -> Bool {
		#if os(macOS)
			await AppleMusicScriptBridge.play(playlist: playlist)
			return true
		#else
			guard let detailed = try? await playlist.with([.entries]),
			      let firstEntry = detailed.entries?.first else { return false }
			do {
				SystemMusicPlayer.shared.queue = .init(playlist: detailed, startingAt: firstEntry)
				try await SystemMusicPlayer.shared.play()
				return true
			} catch {
				print("Playback error:", error)
				return false
			}
		#endif
	}

	/// macOS plays only `songs.first` (the seed) and relies on Music.app's
	/// Autoplay to continue; iOS enqueues the full runway through
	/// `SystemMusicPlayer`. Trade-off documented in the bridge.
	@discardableResult
	static func play(songs: [Song]) async -> Bool {
		guard let seed = songs.first else { return false }
		#if os(macOS)
			await AppleMusicScriptBridge.play(song: seed)
			return true
		#else
			do {
				SystemMusicPlayer.shared.queue = .init(for: songs)
				try await SystemMusicPlayer.shared.play()
				return true
			} catch {
				print("Playback error:", error)
				return false
			}
		#endif
	}
}
