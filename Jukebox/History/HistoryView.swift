//
//  HistoryView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Browse past Songs-mode runways logged by `HistoryStore`.

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
		// macOS sheets get no detent sizing; without a frame the
		// NavigationStack collapses to just the title bar.
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
	/// Pre-rendered PNG for `ShareLink`. Nil until the render finishes so
	/// the share affordance only enables once the bytes exist.
	@State private var coverShare: PlaylistCoverImage?
	/// Gates a placeholder until palette + render finish, so the cover
	/// doesn't flash the neutral fallback before its real colors.
	@State private var coverLoaded = false
	/// Editable display name, mirrored to `HistoryPlaylist.name` via the store.
	@State private var name: String = ""
	/// Suppresses the rename-handler on the first `name` write from the
	/// entry — otherwise the initial `.task` triggers a no-op save + re-render.
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
			ToolbarItem(placement: .secondaryAction) {
				feedbackMenu
			}
			ToolbarItem(placement: .primaryAction) {
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
			.frame(height: 44)
			.scenePadding(.horizontal)
			.scenePadding(.bottom)
		}
	}

	/// Stable per-playlist gradient seed, from the first 8 bytes of the
	/// entry's UUID — distinct per playlist, consistent across re-renders.
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

	/// Square placeholder matching the cover's dimensions, shown while
	/// palette extraction and the PNG render are in flight.
	private var coverPlaceholder: some View {
		let side: CGFloat = 280
		return RoundedRectangle(cornerRadius: side * 0.045)
			.fill(.regularMaterial)
			.frame(width: side, height: side)
			.overlay {
				ProgressView()
			}
	}

	/// An emptied name falls back to the seed title so the cover never
	/// reads blank, matching `HistoryEntrySnapshot.displayName`.
	private var coverTitle: String {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? entry.seedTitle : trimmed
	}

	/// Extract a dominant-color palette from the leading songs, then bake
	/// the share PNG.
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

	/// Re-render the share PNG. Cheap (~50ms), so run inline on every
	/// rename rather than debouncing.
	private func rerenderCoverShare() {
		guard let png = PlaylistCoverRenderer.renderPNG(
			title: coverTitle,
			palette: coverPalette,
			seed: coverSeed
		) else { return }
		coverShare = PlaylistCoverImage(title: coverTitle, pngData: png)
	}

	/// Persist a rename + refresh the share PNG.
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

	/// Blocks the pair so the next walk won't recreate the transition, and
	/// removes the song from the entry's persistent rows so the cleanup
	/// survives a relaunch.
	private func dropPair(prevID: String, currID: String) async {
		await TransitionFeedbackStore.shared.block(prevID, currID)
		await HistoryStore.shared.removeSong(songID: currID, from: entry.id)
		withAnimation(.snappy) {
			songs.removeAll { $0.id == currID }
		}
	}

	/// Persist run-level feedback; a Bad Run also bulk-blocks every
	/// remaining adjacent pair. One-way — unmarking doesn't unwind the blocks.
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
		try await songs.resolveLibrarySongs()
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
