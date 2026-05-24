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

	/// Play a runway of songs. iOS enqueues the whole array through
	/// `SystemMusicPlayer`; macOS stages them into a recycled
	/// `▶ Playback` user playlist (Music.app exposes no scriptable
	/// "Up Next") and plays that.
	@discardableResult
	static func play(songs: [Song]) async -> Bool {
		guard !songs.isEmpty else { return false }
		#if os(macOS)
			await AppleMusicScriptBridge.play(songs: songs)
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
