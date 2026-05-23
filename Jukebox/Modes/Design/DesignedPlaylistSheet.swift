//
//  DesignedPlaylistSheet.swift
//  Jukebox
//
//  Sheet shown after Generate. Mirrors HistoryDetailView's ergonomics
//  (numbered list, Play queues the full runway through SystemMusicPlayer,
//  Save persists into Apple Music via MusicLibrary.createPlaylist) but
//  is owned by Design mode so we can plot the requested-vs-achieved
//  band per row.
//

import MusicKit
import SwiftUI

struct DesignedPlaylistSheet: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) private var colorScheme

	let curve: EnergyCurve
	let songs: [Song]
	let bandsUsed: [EnergyBand]
	let suggestedName: String

	@State private var draftName: String = ""
	@State private var showingSaveDialog = false
	@State private var saveError: String?
	@State private var savedAcknowledgement: String?

	var body: some View {
		NavigationStack {
			List {
				Section {
					curveHeader
						.listRowInsets(EdgeInsets())
						.listRowBackground(Color.clear)
				}
				Section {
					ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
						row(index: idx, song: song)
					}
				}
			}
			.navigationTitle(suggestedName)
			.inlineNavigationTitle()
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(role: .close) { dismiss() }
				}
				ToolbarItem(placement: .primaryAction) {
					Button {
						draftName = suggestedName
						showingSaveDialog = true
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
					Task { await save(named: chosen) }
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
			.alert(
				"Saved",
				isPresented: Binding(get: { savedAcknowledgement != nil }, set: { if !$0 { savedAcknowledgement = nil } })
			) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(savedAcknowledgement ?? "")
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
		#if os(macOS)
		.frame(minWidth: 420, idealWidth: 480, minHeight: 480, idealHeight: 600)
		#endif
	}

	private var curveHeader: some View {
		VStack(alignment: .leading, spacing: 12) {
			EnergyCurveEditor(curve: .constant(curve))
				.frame(height: 160)
				.allowsHitTesting(false)
		}
		.padding(.vertical, 8)
	}

	private func row(index: Int, song: Song) -> some View {
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
			VStack(spacing: 2) {
				Text(String(format: "%02d", index + 1))
					.font(.system(.caption, design: .monospaced))
					.monospacedDigit()
					.foregroundStyle(.secondary)
				Circle()
					.fill(bandsUsed.indices.contains(index) ? bandsUsed[index].tint : .secondary)
					.frame(width: 6, height: 6)
			}
		}
		.padding(.vertical, 2)
	}

	private func subtitleText(for song: Song) -> String {
		if let album = song.albumTitle, !album.isEmpty {
			return "\(song.artistName) — \(album)"
		}
		return song.artistName
	}

	private func playAll() async {
		await MusicPlayback.play(songs: songs)
	}

	private func save(named rawName: String) async {
		let name = rawName.isEmpty ? suggestedName : rawName
		#if os(iOS)
			do {
				_ = try await MusicLibrary.shared.createPlaylist(
					name: name,
					description: "Designed in Playback",
					items: songs
				)
				savedAcknowledgement = "Saved \"\(name)\" to your Apple Music library."
			} catch {
				saveError = error.localizedDescription
			}
		#else
			// MusicLibrary.createPlaylist is iOS-only — Apple's macOS MusicKit
			// surface has no library-mutation API.
			_ = name
			saveError = "Saving to your library isn't available on macOS yet."
		#endif
	}
}
