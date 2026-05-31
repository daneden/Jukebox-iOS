//
//  SaveToLibrary.swift
//  Jukebox
//
//  Materializes a generated playlist into the Apple Music library — the
//  Siri/Shortcuts surface for History's "Save to library".
//

import AppIntents
import Foundation
import MusicKit

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
struct SaveToLibrary: AppIntent {
	static var title: LocalizedStringResource = "Save Playlist to Library"
	static var description = IntentDescription(
		"Saves a generated playlist to your Music library."
	)

	/// Unset → the most recently generated playlist.
	@Parameter(title: "Playlist")
	var playlist: GeneratedPlaylistEntity?

	/// Unset → the playlist's existing name.
	@Parameter(title: "Name")
	var name: String?

	static var parameterSummary: some ParameterSummary {
		Summary("Save \(\.$playlist) to your library") {
			\.$name
		}
	}

	func perform() async throws -> some IntentResult & ProvidesDialog {
		let entry: HistoryEntrySnapshot
		if let playlist {
			guard let resolved = await HistoryStore.shared.entry(id: playlist.id) else {
				throw PlaybackIntentError.nothingToSave
			}
			entry = resolved
		} else {
			guard let recent = await HistoryStore.shared.recent(limit: 1).first else {
				throw PlaybackIntentError.nothingToSave
			}
			entry = recent
		}

		let songs = try await entry.songs.resolveLibrarySongs()
		guard !songs.isEmpty else { throw PlaybackIntentError.songsUnavailable }

		let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
		let playlistName = (trimmed?.isEmpty == false) ? trimmed! : entry.displayName
		_ = try await MusicPlayback.save(
			songs: songs,
			asPlaylistNamed: playlistName,
			description: "Made with Playback"
		)

		let n = songs.count
		return .result(dialog: "Saved “\(playlistName)” with \(n) song\(n == 1 ? "" : "s").")
	}
}
