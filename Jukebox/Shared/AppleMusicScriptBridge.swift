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
//  Every script returns either "OK" / "OK <key>=<value>" or "ERR …" so a
//  failure inside Music.app surfaces to OSLog (`subsystem
//  me.daneden.Jukebox`, category `AppleScript`) and bubbles up as a thrown
//  `BridgeError`. Never wrap a script body in a bare `try ... end try` —
//  that silently swallows real failures and was the original reason play
//  appeared dead on TestFlight builds.
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

		/// Name of the recycled playlist used to play an arbitrary song
		/// sequence. Triangle prefix sorts it visually distinct in the
		/// sidebar so the user can spot it as a Playback-managed slot.
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
				log.warning("AEDeterminePermissionToAutomateTarget returned \(result)")
			}
			return result == noErr
		}

		/// Ensure Music.app's process exists and has finished launching.
		/// Library hydration happens later — `waitForLibrary` polls for it
		/// separately so the AppleScript itself stays one-shot and we don't
		/// block the main thread for seconds inside `executeAndReturnError`.
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

		/// Poll for Music's library to have hydrated at least one playlist.
		/// On cold launch (especially right after sign-in) the process exists
		/// but `count of playlists` reads 0 for a couple of seconds. We do
		/// the wait in Swift so the AppleScript bodies can stay one-shot.
		private static func waitForLibrary() async throws {
			for _ in 0 ..< 80 {
				let result = try run("tell application \"Music\" to return (count of playlists) as string")
				if let n = Int(result), n > 0 { return }
				try? await Task.sleep(for: .milliseconds(125))
			}
			throw BridgeError.libraryNotReady
		}

		// MARK: - Public verbs

		/// Play a library playlist by name. Match order: user playlist →
		/// non-smart library playlist → any playlist. Duplicate names
		/// resolve to the first match (MusicKit doesn't expose Music.app's
		/// persistent ID so name is our only key).
		static func play(playlist: Playlist) async throws {
			await launchMusicIfNeeded()
			try await waitForLibrary()
			let name = escape(playlist.name)
			let result = try run("""
			tell application "Music"
				set matches to (every user playlist whose name is "\(name)")
				if (count of matches) is 0 then
					set matches to (every library playlist whose name is "\(name)" and smart is false)
				end if
				if (count of matches) is 0 then
					set matches to (every library playlist whose name is "\(name)")
				end if
				if (count of matches) is 0 then
					set matches to (every playlist whose name is "\(name)")
				end if
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

		/// Stage an ordered list of songs into a recycled `▶ Playback` user
		/// playlist and play it. This is the macOS counterpart to iOS's
		/// `SystemMusicPlayer.queue = .init(for: songs)`: Music.app has no
		/// scriptable "Up Next" verb, so a real playlist is the only way to
		/// hand it a multi-track queue.
		///
		/// Tracks are matched by `name + artist`; if that misses we retry
		/// by `name` alone (Music.app drops trailing parenthetical bits
		/// like `(feat. X)` and `(Remastered 2011)` that MusicKit returns).
		/// Unmatched songs are skipped, but if *zero* match we throw rather
		/// than playing an empty queue.
		static func play(songs: [Song]) async throws {
			guard !songs.isEmpty else { return }
			await launchMusicIfNeeded()
			try await waitForLibrary()

			let result = try run(queueScript(
				queuePlaylistName: queuePlaylistName,
				songs: songs,
				playAfter: true
			))

			let matched = matchedCount(in: result) ?? 0
			log.info("play(songs:) matched \(matched)/\(songs.count)")
			if matched == 0 {
				throw BridgeError.noTracksMatched(requested: songs.count)
			}
		}

		/// Create a brand-new user playlist with the given name and
		/// description, populate it from the given songs, and return the
		/// number of tracks that actually matched. Caller decides whether a
		/// partial match counts as success.
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

		/// Build the queue-staging script. Used by `play(songs:)`; the
		/// `playAfter` flag exists so a future caller can stage without
		/// auto-play if needed.
		private static func queueScript(queuePlaylistName: String, songs: [Song], playAfter: Bool) -> String {
			let escapedQueueName = escape(queuePlaylistName)
			let titlesLiteral = literalList(songs.map(\.title))
			let artistsLiteral = literalList(songs.map(\.artistName))
			let playClause = playAfter ? "play queueList" : ""

			return """
			tell application "Music"
				set queueName to "\(escapedQueueName)"
				set existing to (every user playlist whose name is queueName)
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
					return "OK matched=0"
				end if

				\(playClause)
				return "OK matched=" & matchedCount
			end tell
			"""
		}

		private static func matchedCount(in result: String) -> Int? {
			guard let range = result.range(of: "matched=") else { return nil }
			return Int(result[range.upperBound ..< result.endIndex])
		}

		/// Wrap a string in AppleScript double-quoted form, escaping `"` and
		/// `\`. AppleScript string literals don't accept raw newlines, so
		/// any LF/CR in the input is replaced with a space rather than
		/// emitting a syntax-error-causing literal break.
		private static func escape(_ string: String) -> String {
			string
				.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"")
				.replacingOccurrences(of: "\n", with: " ")
				.replacingOccurrences(of: "\r", with: " ")
		}

		/// Turn a Swift `[String]` into an AppleScript list literal:
		/// `{"a", "b", "c"}`. Empty list becomes `{}` which AppleScript
		/// accepts.
		private static func literalList(_ strings: [String]) -> String {
			let items = strings.map { "\"\(escape($0))\"" }.joined(separator: ", ")
			return "{\(items)}"
		}

		/// Synchronously execute a script and return its trimmed string
		/// result. Errors are logged with their AppleScript code (e.g. -1743
		/// = TCC denied, -1728 = no such object, -10004 = privilege denied,
		/// -600 = Music.app not running) and thrown so callers can decide
		/// what to surface.
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
				log.error("AppleScript error \(code, privacy: .public): \(message, privacy: .public)")
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
	}
#endif
