//
//  AppleMusicScriptBridge.swift
//  Jukebox
//
//  macOS-only. MusicKit on macOS only ships `ApplicationMusicPlayer`, which
//  plays audio in-process and doesn't touch Music.app's queue or Now Playing
//  state. To get iOS-like behaviour (the user lands on a playlist/song and
//  Music.app picks it up) we drive Music.app's AppleScript dictionary.
//
//  Sandbox requires `com.apple.security.scripting-targets` with
//  `com.apple.Music` → `playback` + `library.read` + `library.read-write`;
//  hardened runtime requires `com.apple.security.automation.apple-events`;
//  Info.plist needs `NSAppleEventsUsageDescription`. Without all three TCC
//  silently denies with -1743 and Playback never appears under System
//  Settings → Privacy & Security → Automation.
//

#if os(macOS)
	import AppKit
	import ApplicationServices
	import Foundation
	import MusicKit

	@MainActor
	enum AppleMusicScriptBridge {
		private static let musicBundleID = "com.apple.Music"

		/// Triggers the "Playback wants to control Music" prompt on the first
		/// call after a fresh install or `tccutil reset AppleEvents
		/// me.daneden.Jukebox`; returns the cached decision instantly thereafter.
		/// Music.app must be running before we ask — otherwise the call returns
		/// -600 (procNotFound) without prompting.
		@discardableResult
		static func requestAutomationPermission() async -> Bool {
			await launchMusicIfNeeded()
			var descriptor = AEAddressDesc()
			let createStatus = musicBundleID.withCString { ptr -> OSErr in
				AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &descriptor)
			}
			guard createStatus == noErr else { return false }
			defer { AEDisposeDesc(&descriptor) }
			let result = AEDeterminePermissionToAutomateTarget(
				&descriptor,
				typeWildCard,
				typeWildCard,
				true
			)
			if result != noErr {
				print("AEDeterminePermissionToAutomateTarget returned \(result)")
			}
			return result == noErr
		}

		/// Ensure Music.app's process exists and has finished launching.
		/// Library hydration takes longer than the process launch; the play
		/// scripts handle that themselves with an in-script wait loop so the
		/// wait + match + play sequence stays inside a single AE round-trip.
		private static func launchMusicIfNeeded() async {
			let runningApp = NSWorkspace.shared.runningApplications.first {
				$0.bundleIdentifier == musicBundleID
			}
			if runningApp == nil {
				guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: musicBundleID) else {
					return
				}
				let config = NSWorkspace.OpenConfiguration()
				config.activates = false
				config.addsToRecentItems = false
				_ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
			}
			for _ in 0 ..< 30 {
				let app = NSWorkspace.shared.runningApplications.first {
					$0.bundleIdentifier == musicBundleID
				}
				if let app, app.isFinishedLaunching { return }
				try? await Task.sleep(for: .milliseconds(100))
			}
		}

		/// Play a library playlist by name. Duplicate names go to Music.app's
		/// first match — MusicKit doesn't expose the persistent ID Music.app
		/// indexes on, so name is our only key.
		static func play(playlist: Playlist) async {
			await launchMusicIfNeeded()
			let name = escape(playlist.name)
			run("""
			tell application "Music"
				set tries to 0
				repeat while (count of playlists) is 0 and tries < 50
					delay 0.1
					set tries to tries + 1
				end repeat
				try
					play playlist "\(name)"
				end try
			end tell
			""")
		}

		/// Play a single song from the user's library, matched by title + artist
		/// (MusicKit library `Song`s don't expose Music.app's persistent track
		/// ID). Music.app's "Up Next" gets cleared by `play`, matching iOS
		/// `SystemMusicPlayer` behaviour.
		///
		/// Tracks are addressed through the application's top-level `track`
		/// element rather than `library playlist 1` — the latter isn't declared
		/// as a direct application element in Music.app's sdef, and referencing
		/// it from a `scripting-targets` sandbox trips -10004 even though
		/// `library.read` covers the playlist class.
		static func play(song: Song) async {
			await launchMusicIfNeeded()
			let title = escape(song.title)
			let artist = escape(song.artistName)
			run("""
			tell application "Music"
				set tries to 0
				repeat while (count of playlists) is 0 and tries < 50
					delay 0.1
					set tries to tries + 1
				end repeat
				try
					set targetTrack to (first track whose name is "\(title)" and artist is "\(artist)")
					play targetTrack
				end try
			end tell
			""")
		}

		private static func escape(_ string: String) -> String {
			string
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"")
		}

		private static func run(_ source: String) {
			guard let script = NSAppleScript(source: source) else { return }
			var error: NSDictionary?
			script.executeAndReturnError(&error)
			if let error {
				print("AppleScript error:", error)
			}
		}
	}
#endif
