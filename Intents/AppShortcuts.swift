//
//  AppShortcuts.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  Voice/Shortcuts trigger phrases. The `\(.applicationName)` token is
//  required by AppIntents — Siri only matches phrases that include the
//  app's name (display name "Playback"), so "Make a playlist with
//  Playback" works while a bare "Make a playlist" does not.

import AppIntents

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
struct JukeboxAppShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: MakeAPlaylist(),
			phrases: [
				"Make a playlist with \(.applicationName)",
				"Make me a playlist with \(.applicationName)",
				"Build a playlist with \(.applicationName)",
				"Play hidden gems with \(.applicationName)",
			],
			shortTitle: "Make a Playlist",
			systemImageName: "music.note.list"
		)
		AppShortcut(
			intent: PlayRandomPlaylist(),
			phrases: [
				"Play a random playlist with \(.applicationName)",
				"Play a random playlist on \(.applicationName)",
				"Shuffle a playlist with \(.applicationName)",
				"Surprise me with \(.applicationName)",
			],
			shortTitle: "Play Random Playlist",
			systemImageName: "shuffle"
		)
	}
}
