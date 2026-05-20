//
//  HistoryView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Browse past Songs-mode "playlists" — the similarity-walked runways
//  that get logged by `HistoryStore` on every play. List of entries on
//  push, song-by-song detail on pop.

import MusicKit
import SwiftUI

struct HistoryView: View {
	@Environment(\.dismiss) private var dismiss

	@State private var entries: [HistoryEntrySnapshot] = []
	@State private var isLoading = true

	var body: some View {
		NavigationStack {
			content
				.navigationTitle("History")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarTrailing) {
						Button(role: .close) { dismiss() }
					}
				}
				.task { await reload() }
		}
	}

	@ViewBuilder
	private var content: some View {
		if entries.isEmpty, !isLoading {
			ContentUnavailableView(
				"No History Yet",
				systemImage: "clock.arrow.circlepath",
				description: Text("Songs you play will show up here, with the similarity playlist they were part of.")
			)
		} else {
			List {
				ForEach(entries) { entry in
					NavigationLink(value: entry) {
						HistoryRow(entry: entry)
					}
				}
				.onDelete(perform: deleteEntries)
			}
			.navigationDestination(for: HistoryEntrySnapshot.self) { entry in
				HistoryDetailView(entry: entry, onChange: { Task { await reload() } })
			}
		}
	}

	private func reload() async {
		let snapshots = await HistoryStore.shared.recent()
		entries = snapshots
		isLoading = false
	}

	private func deleteEntries(at offsets: IndexSet) {
		let ids = offsets.map { entries[$0].id }
		entries.remove(atOffsets: offsets)
		Task {
			for id in ids {
				await HistoryStore.shared.delete(id: id)
			}
		}
	}
}

private struct HistoryRow: View {
	let entry: HistoryEntrySnapshot

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			VStack(alignment: .leading, spacing: 4) {
				Text(entry.displayName)
					.font(.headline)
					.lineLimit(1)
				HStack(spacing: 6) {
					Text(entry.playedAt, format: .relative(presentation: .named))
					Text("·")
					Text("^[\(entry.songs.count) song](inflect: true)")
				}
				.font(.caption)
				.foregroundStyle(.tertiary)
			}
			Spacer(minLength: 0)
			feedbackGlyph
		}
		.padding(.vertical, 2)
	}

	@ViewBuilder
	private var feedbackGlyph: some View {
		switch entry.feedback {
		case .liked:
			Image(systemName: "hand.thumbsup.fill")
				.font(.footnote)
				.foregroundStyle(.green)
				.accessibilityLabel("Marked as a good run")
		case .disliked:
			Image(systemName: "hand.thumbsdown.fill")
				.font(.footnote)
				.foregroundStyle(.red)
				.accessibilityLabel("Marked as a bad run")
		case .none:
			EmptyView()
		}
	}
}

private struct HistoryDetailView: View {
	@Environment(\.colorScheme) private var colorScheme
	let entry: HistoryEntrySnapshot
	let onChange: () -> Void

	@State private var songs: [SongSnapshot] = []
	@State private var feedback: HistoryFeedback = .none
	@State private var showingSaveDialog = false
	@State private var draftName: String = ""
	@State private var saveError: String?

	var body: some View {
		List {
			ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
				row(index: index, song: song)
			}
		}
		.task {
			songs = entry.songs
			feedback = entry.feedback
		}
		.onDisappear { onChange() }
		.navigationTitle(entry.displayName)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				feedbackMenu
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					presentSaveDialog()
				} label: {
					Label("Save to Library", systemImage: "plus")
				}
				.disabled(songs.isEmpty)
			}
		}
		.alert("Save to Apple Music", isPresented: $showingSaveDialog) {
			TextField("Playlist name", text: $draftName)
			Button("Save") {
				let chosen = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
				Task { await saveAsPlaylist(named: chosen) }
			}
			Button("Cancel", role: .cancel) {}
		}
		.alert(
			"Couldn't save playlist",
			isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
		) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(saveError ?? "")
		}
		.safeAreaBar(edge: .bottom) {
			AsyncButton(action: playAll) {
				Label("Play", systemImage: "play.fill")
					.frame(maxWidth: .infinity)
					.foregroundStyle(colorScheme == .dark ? .black : .white)
			}
			.fontWeight(.bold)
			.buttonStyle(.glassProminent)
			.buttonBorderShape(.capsule)
			.controlSize(.large)
			.disabled(songs.isEmpty)
			.frame(height: 56)
			.scenePadding(.horizontal)
			.scenePadding(.bottom)
		}
	}

	private var feedbackMenu: some View {
		Menu {
			Button {
				setFeedback(feedback == .liked ? .none : .liked)
			} label: {
				Label(
					feedback == .liked ? "Unmark Good Run" : "Good Run",
					systemImage: "hand.thumbsup"
				)
			}
			Button(role: .destructive) {
				setFeedback(feedback == .disliked ? .none : .disliked)
			} label: {
				Label(
					feedback == .disliked ? "Unmark Bad Run" : "Bad Run",
					systemImage: "hand.thumbsdown"
				)
			}
		} label: {
			switch feedback {
			case .liked:
				Image(systemName: "hand.thumbsup.fill")
					.foregroundStyle(.green)
					.accessibilityLabel("Run feedback")
			case .disliked:
				Image(systemName: "hand.thumbsdown.fill")
					.foregroundStyle(.red)
					.accessibilityLabel("Run feedback")
			case .none:
				Image(systemName: "ellipsis.circle")
					.accessibilityLabel("Rate this run")
			}
		}
	}

	private func row(index: Int, song: SongSnapshot) -> some View {
		Label {
			VStack(alignment: .leading, spacing: 2) {
				Text(song.title)
					.lineLimit(1)
				Text(subtitleText(for: song))
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		} icon: {
			Text(String(format: "%02d", index + 1))
				.font(.system(.body, design: .monospaced))
				.monospacedDigit()
				.foregroundStyle(.secondary)
		}
		.padding(.vertical, 2)
		.swipeActions(edge: .trailing, allowsFullSwipe: false) {
			if index > 0 {
				let prevID = songs[index - 1].id
				let currID = song.id
				Button(role: .destructive) {
					Task { await dropPair(prevID: prevID, currID: currID) }
				} label: {
					Label("Don't Pair", systemImage: "hand.thumbsdown")
				}
			}
		}
	}

	/// Drops the song from the displayed playlist and records the pair
	/// as blocked so the next walk won't recreate the transition. The
	/// song is removed from this entry's persistent rows too — we want
	/// the cleaned playlist to survive a relaunch.
	private func dropPair(prevID: String, currID: String) async {
		await TransitionFeedbackStore.shared.block(prevID, currID)
		await HistoryStore.shared.removeSong(songID: currID, from: entry.id)
		withAnimation(.snappy) {
			songs.removeAll { $0.id == currID }
		}
	}

	/// Persist run-level feedback, and on Bad Run also bulk-block every
	/// remaining adjacent pair. The bulk-block is intentionally one-way
	/// — unmarking a Bad Run doesn't unwind the recorded blocks. If the
	/// user wants those back, they'd need explicit per-pair undo (not
	/// in v1).
	private func setFeedback(_ new: HistoryFeedback) {
		feedback = new
		let snapshotSongs = songs
		Task {
			await HistoryStore.shared.setFeedback(new, for: entry.id)
			if new == .disliked, snapshotSongs.count > 1 {
				for i in 1 ..< snapshotSongs.count {
					await TransitionFeedbackStore.shared.block(
						snapshotSongs[i - 1].id,
						snapshotSongs[i].id
					)
				}
			}
		}
	}

	private func presentSaveDialog() {
		draftName = entry.displayName
		showingSaveDialog = true
	}

	private func fetchSongs() async throws -> [Song] {
		let ids = songs.map { MusicItemID($0.id) }
		guard !ids.isEmpty else { return [] }
		var request = MusicLibraryRequest<Song>()
		request.filter(matching: \.id, memberOf: ids)
		let response = try await request.response()
		let byID = Dictionary(uniqueKeysWithValues: response.items.map { ($0.id, $0) })
		return ids.compactMap { byID[$0] }
	}

	private func saveAsPlaylist(named rawName: String) async {
		let name = rawName.isEmpty ? entry.seedTitle : rawName
		do {
			let resolved = try await fetchSongs()
			guard !resolved.isEmpty else {
				saveError = "None of these songs are in your Apple Music library anymore."
				return
			}
			_ = try await MusicLibrary.shared.createPlaylist(
				name: name,
				description: "Made with Playback",
				items: resolved
			)
		} catch {
			saveError = error.localizedDescription
		}
	}

	private func subtitleText(for song: SongSnapshot) -> String {
		if let album = song.albumTitle, !album.isEmpty {
			return "\(song.artistName) — \(album)"
		}
		return song.artistName
	}

	private func playAll() async {
		do {
			let resolved = try await fetchSongs()
			guard !resolved.isEmpty else { return }
			SystemMusicPlayer.shared.queue = .init(for: resolved)
			try await SystemMusicPlayer.shared.play()
		} catch {
			print("History play error: \(error)")
		}
	}
}

#Preview {
	HistoryView()
}
