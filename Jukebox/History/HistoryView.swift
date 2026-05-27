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
				.inlineNavigationTitle()
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button(role: .close) { dismiss() }
					}
				}
				.task { await reload() }
		}
		#if os(macOS)
		// macOS sheets don't get iOS's automatic detent sizing — without
		// a frame, NavigationStack collapses to just the title bar.
		.frame(minWidth: 420, idealWidth: 480, minHeight: 480, idealHeight: 600)
		#endif
	}

	@ViewBuilder
	private var content: some View {
		if entries.isEmpty, !isLoading {
			ContentUnavailableView(
				"No history yet",
				systemImage: "clock.arrow.circlepath",
				description: Text("Songs you play will show up here, along with the other songs queued up alongside them.")
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

struct HistoryDetailView: View {
	@Environment(\.colorScheme) private var colorScheme
	let entry: HistoryEntrySnapshot
	let onChange: () -> Void

	@State private var songs: [SongSnapshot] = []
	@State private var feedback: HistoryFeedback = .none
	@State private var showingSaveDialog = false
	@State private var draftName: String = ""
	@State private var saveError: String?
	@State private var coverPalette: [Color]?
	/// Pre-rendered PNG for `ShareLink`. Stays nil until palette + render
	/// finish so the share affordance only enables when the bytes exist.
	@State private var coverShare: PlaylistCoverImage?
	/// Flips once palette extraction and PNG render have both completed.
	/// Until then we show a placeholder rather than the fallback gradient,
	/// so the cover doesn't flash neutral-default before its real colors.
	@State private var coverLoaded = false
	/// Editable display name, mirrored to `HistoryPlaylist.name` via the
	/// store. Drives both the navigation title (renamable through the
	/// binding-form `.navigationTitle(_:)`) and the cover art.
	@State private var name: String = ""
	/// Suppresses the rename-handler the first time `name` is populated
	/// from the entry — without it the initial `.task` write would trip
	/// a no-op save and a redundant PNG re-render.
	@State private var nameInitialized = false

	var body: some View {
		List {
			Section {
				coverArtRow
					.listRowSeparator(.hidden)
					.listRowBackground(Color.clear)
					.listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
			}
			Section {
				ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
					row(index: index, song: song)
				}
			}
		}
		.task {
			songs = entry.songs
			feedback = entry.feedback
			name = entry.displayName
			await loadCoverArt()
			nameInitialized = true
		}
		.onDisappear { onChange() }
		.navigationTitle($name)
		.inlineNavigationTitle()
		.onChange(of: name) { _, new in
			handleRename(new)
		}
		.toolbar {
			ToolbarItem {
				feedbackMenu
			}
			ToolbarItem {
				Button {
					presentSaveDialog()
				} label: {
					Label("Save to library", systemImage: "plus")
				}
				.disabled(songs.isEmpty)
			}
			ToolbarTitleMenu {
				RenameButton()
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
			#if os(iOS)
				.scenePadding(.bottom)
			#endif
		}
	}

	/// Generated cover art for this history playlist. Tap to share/save —
	/// MusicKit's library API can't apply custom artwork to a saved
	/// playlist (see `project-musickit-no-artwork`), so this is a manual
	/// hand-off via the system share sheet.
	/// Stable per-playlist seed for the cover's gradient layout. Pulled
	/// from the first 8 bytes of the entry's UUID so different playlists
	/// get distinct gradients while a single playlist's cover stays
	/// visually consistent across re-renders.
	private var coverSeed: UInt64 {
		withUnsafeBytes(of: entry.id.uuid) { ptr in
			ptr.load(fromByteOffset: 0, as: UInt64.self)
		}
	}

	private var coverArtRow: some View {
		HStack {
			Spacer(minLength: 0)
			if coverLoaded {
				let cover = PlaylistCoverArt(
					title: coverTitle,
					palette: coverPalette,
					seed: coverSeed
				)
				if let coverShare {
					ShareLink(
						item: coverShare,
						preview: SharePreview(coverTitle)
					) {
						cover
					}
					.buttonStyle(.plain)
					.draggable(coverShare) { cover }
				} else {
					cover
				}
			} else {
				coverPlaceholder
			}
			Spacer(minLength: 0)
		}
	}

	/// Square placeholder matching the cover's dimensions and corner
	/// radius. Used while palette extraction and the PNG render are
	/// still in flight; flipping `coverLoaded` swaps it out for the
	/// real cover in a single transition.
	private var coverPlaceholder: some View {
		let side: CGFloat = 280
		return RoundedRectangle(cornerRadius: side * 0.045)
			.fill(.regularMaterial)
			.frame(width: side, height: side)
			.overlay {
				ProgressView()
			}
	}

	/// What the cover should render. An emptied name (the user cleared
	/// the title field) falls back to the seed title so the cover never
	/// reads blank, matching `HistoryEntrySnapshot.displayName`'s rule.
	private var coverTitle: String {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? entry.seedTitle : trimmed
	}

	/// Pull a handful of dominant colors from the runway's leading songs,
	/// then bake a PNG via `ImageRenderer` for sharing. The displayed
	/// view picks up the palette as soon as it's available; the share
	/// affordance lights up after the PNG finishes.
	private func loadCoverArt() async {
		let resolved = (try? await fetchSongs()) ?? []
		let palette = await PlaylistCoverPalette.extract(from: resolved, maxColors: 4)
		let paletteForRender = palette.isEmpty ? nil : palette
		coverPalette = paletteForRender
		rerenderCoverShare()
		withAnimation(.smooth(duration: 0.25)) {
			coverLoaded = true
		}
	}

	/// Synchronously re-render the share PNG for the current title +
	/// palette. Cheap (~50ms) so we run it inline on every rename rather
	/// than debouncing.
	private func rerenderCoverShare() {
		guard let png = PlaylistCoverRenderer.renderPNG(
			title: coverTitle,
			palette: coverPalette,
			seed: coverSeed
		) else { return }
		coverShare = PlaylistCoverImage(title: coverTitle, pngData: png)
	}

	/// Persist a rename + refresh the share PNG. Skipped on the initial
	/// task-driven assignment so we don't churn the store with a no-op
	/// save the first time the detail view opens.
	private func handleRename(_ newValue: String) {
		guard nameInitialized else { return }
		let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
		let entryID = entry.id
		Task {
			await HistoryStore.shared.rename(id: entryID, to: trimmed)
		}
		rerenderCoverShare()
	}

	private var feedbackMenu: some View {
		Menu {
			Button {
				setFeedback(feedback == .liked ? .none : .liked)
			} label: {
				Label(
					feedback == .liked ? "Unmark good run" : "Good run",
					systemImage: "hand.thumbsup"
				)
			}
			Button(role: .destructive) {
				setFeedback(feedback == .disliked ? .none : .disliked)
			} label: {
				Label(
					feedback == .disliked ? "Unmark bad run" : "Bad run",
					systemImage: "hand.thumbsdown"
				)
			}
		} label: {
			switch feedback {
			case .liked:
				Label("Rate playlist", systemImage: "hand.thumbsup.fill")
					.foregroundStyle(.green)
			case .disliked:
				Label("Rate playlist", systemImage: "hand.thumbsdown.fill")
					.foregroundStyle(.red)
			case .none:
				Label("Rate playlist", systemImage: "hand.thumbsup")
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
				.font(.system(.caption, design: .monospaced))
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
					Label("Don't pair", systemImage: "hand.thumbsdown")
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
			_ = try await MusicPlayback.save(
				songs: resolved,
				asPlaylistNamed: name,
				description: "Made with Playback"
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
			await MusicPlayback.play(songs: resolved)
		} catch {
			print("History play error: \(error)")
		}
	}
}

#Preview {
	HistoryView()
}
