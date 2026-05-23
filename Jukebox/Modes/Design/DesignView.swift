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

	@AppStorage(SettingsKeys.designCurveData) private var curveData: Data = Data()
	@AppStorage(SettingsKeys.designSongCount) private var songCount: Int = 20

	@State private var curve: EnergyCurve = .default
	@State private var isGenerating = false
	@State private var generationError: String?
	@State private var result: DesignedPlaylistResult?

	var body: some View {
		NavigationStack {
			VStack(spacing: 16) {
				#if os(macOS)
					ToolbarLogo()
						.padding(.top, 8)
				#endif

				header

				EnergyCurveEditor(curve: $curve)
					.padding(.horizontal)
					.padding(.vertical, 8)
					.onChange(of: curve) { _, newValue in persist(newValue) }

				bandAxisLegend

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
			.sheet(item: $result) { result in
				DesignedPlaylistSheet(
					curve: result.curve,
					songs: result.songs,
					bandsUsed: result.bandsUsed,
					suggestedName: result.name
				)
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

	private var header: some View {
		VStack(spacing: 4) {
			Text("Design")
				.font(.title2)
				.fontWeight(.semibold)
			Text("Drag the points to shape how energy moves over the playlist.")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 24)
		}
	}

	/// Tiny key for the vertical axis. Repeats the EnergyBand tints so the
	/// curve's gradient reads as a band scale rather than abstract colour.
	private var bandAxisLegend: some View {
		HStack(spacing: 8) {
			ForEach(EnergyBand.concreteOrdered) { band in
				HStack(spacing: 4) {
					Circle()
						.fill(band.tint)
						.frame(width: 8, height: 8)
					Text(band.displayName)
						.font(.caption)
						.fontWidth(band.fontWidth)
				}
			}
		}
		.foregroundStyle(.secondary)
		.padding(.horizontal)
	}

	private var songCountSlider: some View {
		VStack(spacing: 4) {
			HStack {
				Text("Songs")
					.font(.subheadline)
				Spacer()
				Text("\(songCount)")
					.font(.subheadline.monospacedDigit())
					.contentTransition(.numericText())
			}
			Slider(
				value: Binding(
					get: { Double(songCount) },
					set: { songCount = Int($0.rounded()) }
				),
				in: 10 ... 50,
				step: 1
			) {
				Text("Number of songs")
			} minimumValueLabel: {
				Text("10").font(.caption)
			} maximumValueLabel: {
				Text("50").font(.caption)
			}
		}
		.padding(.horizontal)
	}

	private var bottomBar: some View {
		GlassEffectContainer(spacing: 8) {
			HStack(spacing: 8) {
				Button {
					withAnimation(.smooth(duration: 0.5)) {
						curve = .random()
					}
				} label: {
					Label("Randomise", systemImage: "shuffle")
						.frame(maxWidth: .infinity)
				}
				.fontWeight(.semibold)
				.buttonStyle(.glass)
				.buttonBorderShape(.capsule)
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
			let built = try await DesignedPlaylistBuilder.build(curve: curve, count: songCount)
			guard !built.songs.isEmpty else {
				generationError = "Couldn't pick any songs for this curve."
				return
			}
			let name = PlaylistNamer.suggestedName(seedArtist: built.songs.first?.artistName)
			let snapshots = built.songs.map(SongSnapshot.init(song:))
			// Record before presenting so a quick dismiss still leaves a
			// row in history — matches the Songs-mode contract.
			if let seed = snapshots.first {
				await HistoryStore.shared.record(
					name: name,
					seed: seed,
					runway: snapshots
				)
			}
			result = DesignedPlaylistResult(
				curve: curve,
				songs: built.songs,
				bandsUsed: built.bandsUsed,
				name: name
			)
		} catch {
			generationError = error.localizedDescription
		}
	}
}

/// Wrapper so `.sheet(item:)` has a single Identifiable handle. The
/// curve travels with the result so the sheet's preview matches the
/// curve the songs were generated against, even if the user drags a
/// new shape while the sheet is open.
struct DesignedPlaylistResult: Identifiable {
	let id = UUID()
	let curve: EnergyCurve
	let songs: [Song]
	let bandsUsed: [EnergyBand]
	let name: String
}

#Preview {
	DesignView()
}
