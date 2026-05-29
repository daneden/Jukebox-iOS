//
//  AppleMusicScriptBridge.swift
//  Jukebox
//
//  macOS MusicKit only ships `ApplicationMusicPlayer` (in-process audio, no
//  Music.app queue/Now Playing), so we drive Music.app's AppleScript dictionary.
//
//  Sandbox needs `com.apple.security.scripting-targets` (com.apple.Music →
//  `playback` + `library.read` + `library.read-write`); hardened runtime needs
//  `com.apple.security.automation.apple-events`; Info.plist needs
//  `NSAppleEventsUsageDescription`. Missing any → TCC silently denies (-1743).
//
//  Every script returns "OK" / "OK <key>=<value>" or "ERR …". Never wrap a
//  script body in a bare `try ... end try` — it swallows real failures (the
//  original cause of play appearing dead on TestFlight).
//

#if os(macOS)
	import AppKit
	import ApplicationServices
	import Foundation
	import MusicKit
	import OSLog

	@MainActor
	enum AppleMusicScriptBridge {
		private static let log = Logger(subsystem: "me.daneden.Jukebox", category: "AppleScript")
		private static let musicBundleID = "com.apple.Music"

		/// Transient playlist staging an ordered song queue (Music.app has no
		/// scriptable "Up Next"). Deleted right after `play` engages — Music
		/// keeps the loaded queue playing once the source is gone. The triangle
		/// prefix lets the next play recycle a leaked instance where delete
		/// didn't fire.
		private static let queuePlaylistName = "▶ Playback"

		enum BridgeError: LocalizedError {
			case scriptCompile
			case scriptError(code: Int, message: String)
			case musicUnreachable
			case libraryNotReady
			case playlistNotFound(name: String)
			case noTracksMatched(requested: Int)

			var errorDescription: String? {
				switch self {
				case .scriptCompile:
					"Couldn't compile the Music script."
				case let .scriptError(code, message):
					"Music script error \(code): \(message)"
				case .musicUnreachable:
					"Couldn't reach Music. Make sure it's installed and Playback is allowed under System Settings → Privacy & Security → Automation."
				case .libraryNotReady:
					"Music is still loading your library. Try again in a moment."
				case let .playlistNotFound(name):
					"Music doesn't have a playlist named \u{201C}\(name)\u{201D}."
				case let .noTracksMatched(requested):
					"None of the \(requested) songs in this set are in your Music library."
				}
			}
		}

		/// Triggers the "Playback wants to control Music" automation prompt.
		/// Music.app must be running first — otherwise the call returns -600
		/// (procNotFound) without prompting.
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
				log.warning("AEDeterminePermissionToAutomateTarget returned \(result)")
			}
			return result == noErr
		}

		/// Ensure Music.app's process exists and has finished launching. Library
		/// hydration is `waitForLibrary`'s job, kept separate so each AppleScript
		/// stays one-shot and doesn't block the main thread for seconds.
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

		/// Poll for Music's library to hydrate at least one playlist. On cold
		/// launch the process exists but `count of playlists` reads 0 for a few
		/// seconds.
		private static func waitForLibrary() async throws {
			for _ in 0 ..< 80 {
				let result = try run("tell application \"Music\" to return (count of playlists) as string")
				if let n = Int(result), n > 0 { return }
				try? await Task.sleep(for: .milliseconds(125))
			}
			throw BridgeError.libraryNotReady
		}

		// MARK: - Public verbs

		/// Play a library playlist by name. The sandbox only authorises the
		/// abstract `playlist` element — enumerating `every user playlist` /
		/// `every library playlist` trips -10004 even with `library.read`. Name
		/// is the only key (MusicKit doesn't expose Music.app's persistent ID),
		/// so duplicate names go to whichever Music finds first.
		static func play(playlist: Playlist) async throws {
			await launchMusicIfNeeded()
			try await waitForLibrary()
			let name = escape(playlist.name)
			let result = try run("""
			tell application "Music"
				set matches to (every playlist whose name is "\(name)")
				if (count of matches) is 0 then
					return "ERR not_found"
				end if
				play (item 1 of matches)
				return "OK"
			end tell
			""")
			if result == "ERR not_found" {
				log.error("play(playlist:) no match for \(playlist.name, privacy: .public)")
				throw BridgeError.playlistNotFound(name: playlist.name)
			}
		}

		/// macOS counterpart to `SystemMusicPlayer.queue = .init(for: songs)`:
		/// stage an ordered queue into a transient playlist, play it, then delete
		/// the playlist once playback engages (Music snapshots the queue at
		/// `play`, so deleting the source keeps playback while leaving the
		/// sidebar clean).
		///
		/// Tracks match by `name + artist`, falling back to `name` alone
		/// (Music.app drops trailing parentheticals like `(feat. X)` that
		/// MusicKit returns). Zero matches throws rather than play an empty queue.
		static func play(songs: [Song]) async throws {
			guard !songs.isEmpty else { return }
			await launchMusicIfNeeded()
			try await waitForLibrary()

			let escapedQueueName = escape(queuePlaylistName)
			let titlesLiteral = literalList(songs.map(\.title))
			let artistsLiteral = literalList(songs.map(\.artistName))

			// Recycle a leaked queue playlist if present (clear + refill rather
			// than stack a duplicate), else create fresh.
			let result = try run("""
			tell application "Music"
				set queueName to "\(escapedQueueName)"
				set existing to (every playlist whose name is queueName)
				if (count of existing) > 0 then
					set queueList to item 1 of existing
					try
						delete every track of queueList
					end try
				else
					set queueList to make new user playlist with properties {name:queueName}
				end if

				set trackTitles to \(titlesLiteral)
				set trackArtists to \(artistsLiteral)
				set matchedCount to 0
				repeat with i from 1 to (count of trackTitles)
					set t to (item i of trackTitles)
					set a to (item i of trackArtists)
					set matches to (every track whose name is t and artist is a)
					if (count of matches) is 0 then
						set matches to (every track whose name is t)
					end if
					if (count of matches) > 0 then
						duplicate (item 1 of matches) to queueList
						set matchedCount to matchedCount + 1
					end if
				end repeat

				if matchedCount is 0 then
					try
						delete queueList
					end try
					return "OK matched=0"
				end if

				play queueList

				-- Poll for playback to actually engage (up to ~4s) so the
				-- queue snapshot is fully resident before we drop the
				-- source. Then a small buffer for Music to finish loading
				-- subsequent tracks into its internal queue.
				repeat 40 times
					if player state is playing then exit repeat
					delay 0.1
				end repeat
				delay 0.5
				try
					delete queueList
				end try

				return "OK matched=" & matchedCount
			end tell
			""")

			let matched = matchedCount(in: result) ?? 0
			log.info("play(songs:) matched \(matched)/\(songs.count)")
			if matched == 0 {
				throw BridgeError.noTracksMatched(requested: songs.count)
			}
		}

		/// Create a user playlist, populate it from `songs`, and return the
		/// matched-track count. Caller decides whether a partial match is success.
		@discardableResult
		static func save(songs: [Song], asPlaylistNamed name: String, description: String) async throws -> Int {
			guard !songs.isEmpty else { return 0 }
			await launchMusicIfNeeded()
			try await waitForLibrary()

			let escapedName = escape(name)
			let escapedDesc = escape(description)
			let titlesLiteral = literalList(songs.map(\.title))
			let artistsLiteral = literalList(songs.map(\.artistName))

			let result = try run("""
			tell application "Music"
				set newList to make new user playlist with properties {name:"\(escapedName)", description:"\(escapedDesc)"}
				set trackTitles to \(titlesLiteral)
				set trackArtists to \(artistsLiteral)
				set matchedCount to 0
				repeat with i from 1 to (count of trackTitles)
					set t to (item i of trackTitles)
					set a to (item i of trackArtists)
					set matches to (every track whose name is t and artist is a)
					if (count of matches) is 0 then
						set matches to (every track whose name is t)
					end if
					if (count of matches) > 0 then
						duplicate (item 1 of matches) to newList
						set matchedCount to matchedCount + 1
					end if
				end repeat
				return "OK matched=" & matchedCount
			end tell
			""")

			let matched = matchedCount(in: result) ?? 0
			log.info("save(songs:as:) matched \(matched)/\(songs.count)")
			if matched == 0 {
				throw BridgeError.noTracksMatched(requested: songs.count)
			}
			return matched
		}

		// MARK: - Script helpers

		private static func matchedCount(in result: String) -> Int? {
			guard let range = result.range(of: "matched=") else { return nil }
			return Int(result[range.upperBound ..< result.endIndex])
		}

		/// Escape a string for an AppleScript literal. Newlines become spaces —
		/// AppleScript literals reject raw LF/CR.
		private static func escape(_ string: String) -> String {
			string
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"")
				.replacingOccurrences(of: "\n", with: " ")
				.replacingOccurrences(of: "\r", with: " ")
		}

		/// Turn a `[String]` into an AppleScript list literal `{"a", "b"}`.
		private static func literalList(_ strings: [String]) -> String {
			let items = strings.map { "\"\(escape($0))\"" }.joined(separator: ", ")
			return "{\(items)}"
		}

		/// Execute a script, returning its trimmed result. Error codes:
		/// -1743 TCC denied, -1728 no such object, -10004 privilege denied
		/// (usually enumerating an undeclared element subclass), -600 Music.app
		/// not running. The failing source snippet is logged alongside.
		@discardableResult
		private static func run(_ source: String) throws -> String {
			guard let script = NSAppleScript(source: source) else {
				log.error("Failed to compile AppleScript")
				throw BridgeError.scriptCompile
			}
			var errorInfo: NSDictionary?
			let descriptor = script.executeAndReturnError(&errorInfo)
			if let errorInfo {
				let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
				let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown"
				let snippet = failingSnippet(in: source, errorInfo: errorInfo)
				log.error("AppleScript error \(code, privacy: .public): \(message, privacy: .public) — at: \(snippet, privacy: .public)")
				if code == -600 || code == -1743 {
					throw BridgeError.musicUnreachable
				}
				throw BridgeError.scriptError(code: code, message: message)
			}
			let result = descriptor.stringValue ?? ""
			if result.hasPrefix("ERR") {
				log.error("AppleScript returned \(result, privacy: .public)")
			} else {
				log.debug("AppleScript returned \(result, privacy: .public)")
			}
			return result
		}

		/// Pull the failing source fragment named by `NSAppleScript.errorRange`
		/// for error logs. "<unknown range>" when the dict carries none.
		private static func failingSnippet(in source: String, errorInfo: NSDictionary) -> String {
			guard let value = errorInfo[NSAppleScript.errorRange] as? NSValue else {
				return "<unknown range>"
			}
			let nsRange = value.rangeValue
			guard nsRange.location != NSNotFound,
			      let range = Range(nsRange, in: source)
			else {
				return "<unknown range>"
			}
			return String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
		}
	}
#endif
