//
//  GeneratedPlaylistEntity.swift
//  Jukebox
//
//  An App Entity wrapping a logged History row, so Shortcuts can pass a
//  just-generated playlist from one action into the next (e.g. Make →
//  Save).
//

import AppIntents
import Foundation

struct GeneratedPlaylistEntity: AppEntity {
	static var typeDisplayRepresentation: TypeDisplayRepresentation {
		"Playlist"
	}

	static var defaultQuery = GeneratedPlaylistQuery()

	let id: UUID
	let name: String
	let songCount: Int

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(
			title: "\(name)",
			subtitle: "\(songCount) song\(songCount == 1 ? "" : "s")"
		)
	}

	init(_ entry: HistoryEntrySnapshot) {
		id = entry.id
		name = entry.displayName
		songCount = entry.songs.count
	}
}

struct GeneratedPlaylistQuery: EntityQuery {
	func entities(for identifiers: [UUID]) async throws -> [GeneratedPlaylistEntity] {
		var results: [GeneratedPlaylistEntity] = []
		for id in identifiers {
			if let entry = await HistoryStore.shared.entry(id: id) {
				results.append(GeneratedPlaylistEntity(entry))
			}
		}
		return results
	}

	func suggestedEntities() async throws -> [GeneratedPlaylistEntity] {
		await HistoryStore.shared.recent(limit: 10).map(GeneratedPlaylistEntity.init)
	}
}
