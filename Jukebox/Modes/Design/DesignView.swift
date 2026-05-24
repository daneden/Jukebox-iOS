//
//  DesignView.swift
//  Jukebox
//
//  Design mode: hand-shape a five-point energy curve, ask for a playlist
//  that transitions between energies along it. Unlike Songs mode (which
//  walks similarity) Design mode commits to a per-slot band — the curve
//  is the brief, the candidate pool gets bucketed by energy, and one
//  song per slot fills the requested band.
//

import MusicKit
import SwiftUI

struct DesignView: View {
	@Environment(\.colorScheme) private var colorScheme

	@AppStorage(SettingsKeys.designCurveData) private var curveData: Data = .init()
	@AppStorage(SettingsKeys.designSongCount) private var songCount: Int = 20

	@State private var curve: EnergyCurve = .default
	@State private var isGenerating = false
	@State private var generationError: String?
	@State private var generatedEntry: HistoryEntrySnapshot?

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				#if os(macOS)
					ToolbarLogo()
						.padding(.top, 8)
				#endif

				EnergyCurveEditor(curve: $curve, songCount: songCount)
					.padding(.horizontal)
					.padding(.vertical, 8)
					.onChange(of: curve) { _, newValue in persist(newValue) }

				songCountSlider

				Spacer(minLength: 0)
			}
			.safeAreaBar(edge: .bottom, alignment: .center) {
				bottomBar
			}
			.toolbar {
				ToolbarItem(placement: .navigation) { SettingsMenu() }
				#if os(iOS)
					ToolbarItem(placement: .principal) { ToolbarLogo() }
				#endif
			}
			.task { restoreCurveIfNeeded() }
			.sheet(item: $generatedEntry) { entry in
				NavigationStack {
					HistoryDetailView(entry: entry, onChange: {})
						.toolbar {
							ToolbarItem(placement: .cancellationAction) {
								Button(role: .close) { generatedEntry = nil }
							}
						}
				}
				#if os(macOS)
				.frame(minWidth: 420, idealWidth: 480, minHeight: 480, idealHeight: 600)
				#endif
			}
			.alert(
				"Couldn't generate",
				isPresented: Binding(get: { generationError != nil }, set: { if !$0 { generationError = nil } })
			) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(generationError ?? "")
			}
		}
	}

	private var songCountSlider: some View {
		VStack(spacing: 12) {
			LabeledContent {
				Text("\(songCount) song\(songCount == 1 ? "" : "s")")
					.monospacedDigit()
			} label: {
				Text("Playlist length")
			}
			
			Slider(
				value: Binding(
					get: { Double(songCount) },
					set: { songCount = Int($0.rounded()) }
				),
				in: 10 ... 50,
				step: 5
			) {
				Text("Number of songs")
			} minimumValueLabel: {
				Text("10").foregroundStyle(.secondary)
			} maximumValueLabel: {
				Text("50").foregroundStyle(.secondary)
			}
		}
		.padding(.horizontal)
	}

	private var bottomBar: some View {
		GlassEffectContainer(spacing: 8) {
			HStack(spacing: 8) {
				Button {
					withAnimation(.smooth) {
						curve = .random()
					}
				} label: {
					Label("Randomise", systemImage: "dice")
				}
				.labelStyle(.iconOnly)
				.fontWeight(.semibold)
				.buttonStyle(.glass)
				.buttonBorderShape(.circle)
				.controlSize(.extraLarge)
				.disabled(isGenerating)

				AsyncButton(action: generate) {
					Label("Generate", systemImage: "sparkles")
						.frame(maxWidth: .infinity)
						.foregroundStyle(generateLabelColor)
				}
				.fontWeight(.bold)
				.buttonStyle(.glassProminent)
				.buttonBorderShape(.capsule)
				.controlSize(.extraLarge)
				.disabled(isGenerating)
			}
			.frame(height: 56)
		}
		.scenePadding(.horizontal)
		#if os(iOS)
			.scenePadding(.bottom)
		#endif
	}

	private var generateLabelColor: Color {
		colorScheme == .dark ? .black : .white
	}

	// MARK: - Persistence

	private func restoreCurveIfNeeded() {
		guard !curveData.isEmpty else { return }
		if let decoded = try? JSONDecoder().decode(EnergyCurve.self, from: curveData),
		   decoded.points.count == EnergyCurve.pointCount
		{
			curve = decoded
		}
	}

	private func persist(_ curve: EnergyCurve) {
		if let encoded = try? JSONEncoder().encode(curve) {
			curveData = encoded
		}
	}

	// MARK: - Generate

	private func generate() async {
		isGenerating = true
		defer { isGenerating = false }
		do {
			let songs = try await DesignedPlaylistBuilder.build(curve: curve, count: songCount)
			guard let firstSong = songs.first else {
				generationError = "Couldn't pick any songs for this curve."
				return
			}
			let name = PlaylistNamer.suggestedName(seedArtist: firstSong.artistName)
			let snapshots = songs.map(SongSnapshot.init(song:))
			await HistoryStore.shared.record(
				name: name,
				seed: snapshots[0],
				runway: snapshots
			)
			// Pull the row back out — `record` may merge into an existing
			// entry, so we can't construct the snapshot client-side.
			// `recent(limit: 1)` is sorted by playedAt desc, and `record`
			// sets playedAt = now on both insert and merge paths, so the
			// just-touched row is always first.
			generatedEntry = await HistoryStore.shared.recent(limit: 1).first
		} catch {
			generationError = error.localizedDescription
		}
	}
}

#Preview {
	DesignView()
}
