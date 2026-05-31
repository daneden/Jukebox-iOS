//
//  IntentActions.swift
//  Jukebox
//
//  Shared business logic behind the playback App Intents and the Control
//  Center controls, so Siri, Shortcuts, and the controls all run one path
//  instead of three drifting copies.
//

import Foundation
import MusicKit

enum IntentActions {
	/// Play a random library playlist. Returns its name (nil if none found)
	/// and whether playback started.
	@discardableResult
	static func playRandomPlaylist() async -> (name: String?, ok: Bool) {
		let request = MusicLibraryRequest<Playlist>()
		guard let response = try? await request.response(),
		      let playlist = response.items.randomElement()
		else {
			return (nil, false)
		}
		let ok = await MusicPlayback.play(playlist: playlist)
		return (playlist.name, ok)
	}

	/// Build a hidden-gems deck (filtered by `controls`), seed a `count`-song
	/// runway near the top, optionally start it, and log it to History.
	/// Returns the recorded entry, or nil if the library yields no deck.
	@discardableResult
	static func makeGemsPlaylist(
		controls: WalkControls = .saved(),
		count: Int = 20,
		startPlaying: Bool = true
	) async throws -> HistoryEntrySnapshot? {
		// `wideSample` + avoid-last (the shuffle path's variety) so repeated
		// runs turn the candidate pool over and don't keep landing the same
		// first artist/decade.
		let result = try await GemDeckBuilder.build(
			controls: controls,
			wideSample: true,
			avoidDecade: AppGroupStore.lastSeedDecade,
			avoidArtist: AppGroupStore.lastSeedArtist
		)
		let deck = result.deck
		guard !deck.isEmpty else { return nil }

		let start = GemDeckBuilder.seedIndex(deckCount: deck.count)
		let runway = GemDeckBuilder.runway(deck: deck, startIndex: start, length: max(1, count))
		guard let seed = runway.first else { return nil }

		if startPlaying, await MusicPlayback.play(songs: runway) == false {
			return nil
		}
		AppGroupStore.lastSeedArtist = seed.artistName
		AppGroupStore.lastSeedDecade = seed.releaseDecade(override: result.originals[seed.id])
		return await record(seed: seed, runway: runway)
	}

	/// Build a curve-shaped playlist, optionally start it, and log it.
	@discardableResult
	static func designPlaylist(
		curve: EnergyCurve,
		count: Int = 20,
		startPlaying: Bool = true
	) async throws -> HistoryEntrySnapshot? {
		let songs = try await DesignedPlaylistBuilder.build(curve: curve, count: count)
		guard let seed = songs.first else { return nil }

		if startPlaying, await MusicPlayback.play(songs: songs) == false {
			return nil
		}
		return await record(seed: seed, runway: songs)
	}

	/// Snapshot + log a generated runway, returning the freshly stored row.
	/// `record` may merge into an existing entry but stamps `playedAt = now`
	/// either way, so the most-recent row is the one we just wrote.
	private static func record(seed: Song, runway: [Song]) async -> HistoryEntrySnapshot? {
		let name = PlaylistNamer.suggestedName(seedArtist: seed.artistName)
		await HistoryStore.shared.record(
			name: name,
			seed: SongSnapshot(song: seed),
			runway: runway.map(SongSnapshot.init(song:))
		)
		return await HistoryStore.shared.recent(limit: 1).first
	}
}
