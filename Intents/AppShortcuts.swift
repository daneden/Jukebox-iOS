//
//  AppShortcuts.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//
//  AppIntents requires the `\(.applicationName)` token — Siri only matches
//  phrases that include the app's name.

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
		AppShortcut(
			intent: DesignPlaylist(),
			phrases: [
				"Design a playlist with \(.applicationName)",
				"Design a playlist in \(.applicationName)",
				"Build an energy curve with \(.applicationName)",
			],
			shortTitle: "Design a Playlist",
			systemImageName: "point.topleft.down.to.point.bottomright.curvepath"
		)
		AppShortcut(
			intent: SaveToLibrary(),
			phrases: [
				"Save that playlist with \(.applicationName)",
				"Save to my library with \(.applicationName)",
				"Save my \(.applicationName) playlist",
			],
			shortTitle: "Save Playlist to Library",
			systemImageName: "plus.rectangle.on.folder"
		)
	}
}
