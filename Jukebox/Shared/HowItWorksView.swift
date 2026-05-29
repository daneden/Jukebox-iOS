//
//  HowItWorksView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  A "show your work" surface for the curious user. Walks through the
//  under-the-hood stages that produce what's on the dial: the funnel
//  from the full library down to the final 300 songs, the similarity-
//  based ordering that threads them into a coherent path, and the
//  audio fingerprint cache that powers the similarity signal.
//

import SwiftUI

struct HowItWorksView: View {
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 32) {
					pickingSection
					orderingSection
					fingerprintSection
					energySection
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 16)
			}
			.navigationTitle("How it works")
			.inlineNavigationTitle()
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(role: .close) { dismiss() }
				}
			}
		}
	}

	// MARK: - Intro

	private var intro: some View {
		Text("Playback surfaces songs you’ve forgotten you love. Here’s how it works.")
			.font(.callout)
			.fontDesign(.serif)
	}

	// MARK: - Picking section

	private var pickingSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			intro

			SongFunnel()
				.frame(maxWidth: .infinity)
				.padding(.vertical, 8)

			body(Text("Three complementary pools of \(GemDeckBuilder.basePoolSize) songs each — songs you used to play a lot, songs you saved long ago but barely touched, and songs you added recently but only half-explored. Together they cover lost favorites, neglected adds, and unfinished discoveries."))

			VStack(alignment: .leading, spacing: 6) {
				bullet(Text("Nostalgia: `log(plays + 1) × min(monthsDormant, 60)`"))
				bullet(Text("Discovery: `monthsInLibrary / (plays + 1)`"))
				bullet(Text("Freshness: `exp(−daysSinceAdded / 90) × log(plays + 1) × dormantWeeks`"))
				bullet(Text("Final score: each is normalised to `[0, 1]` across the pool, then blended `0.50` nostalgia + `0.25` discovery + `0.25` freshness"))
				bullet(Text("Recently-played songs are down-ranked, not excluded — songs played today score at `10%`, recovering linearly over `14 days`"))
				bullet(Text("After scoring, no more than `\(GemDeckBuilder.perArtistCap)` songs per artist or `\(GemDeckBuilder.perAlbumCap)` per album make the cut"))
			}
			.font(.footnote)
			.fontDesign(.serif)
			.foregroundStyle(.secondary)
		}
	}

	// MARK: - Ordering section

	private var orderingSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeading("Ordering the songs")

			body(Text("The final \(GemDeckBuilder.deckSize) songs are threaded into a path where consecutive entries share sonic mood. Each step picks the next song with the highest similarity to the previous, with diversity rules so the path doesn’t clump:"))

			VStack(alignment: .leading, spacing: 6) {
				bullet(Text("No same artist within the previous `\(SongDeckWalk.artistLookback)` songs"))
				bullet(Text("No same album within the previous `\(SongDeckWalk.albumLookback)` songs"))
				bullet(Text("Pairs you’ve flagged as bad are skipped"))
			}
			.font(.footnote)
			.fontDesign(.serif)
			.foregroundStyle(.secondary)

			body(Text("The starting song is picked from the top `\(SongDeckWalk.seedTier)` by score, biased away from the artist and decade you last landed on so shuffles actually jump."))

			body(Text("Filters (Energy, Decade, Variety) feed into the same pipeline. Energy and Decade narrow the pool *before* scoring; Variety changes how greedy the ordering is — Steady stays close to the starting song’s mood, Varied lets less-similar candidates win sometimes."))
		}
	}

	// MARK: - Fingerprint section

	private var fingerprintSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeading("Audio fingerprints")

			body(Text("Each song’s audio is fingerprinted from its 30-second preview using Apple’s built-in audio analyzer. The resulting 512-number vector captures the song’s sonic character and is cached locally on your device."))

			body(Text("Cosine similarity between two vectors tells the ordering how alike two songs sound. That signal is blended with tempo, genre, and release date so the ordering can tell apart songs the embedding bunches together. Weights depend on what’s cached:"))

			VStack(alignment: .leading, spacing: 6) {
				bullet(Text("Full signal: `35%` fingerprint + `20%` tempo + `20%` genre + `25%` release date"))
				bullet(Text("No tempo cached: `40%` fingerprint + `25%` genre + `35%` release date"))
				bullet(Text("No fingerprint yet: `50%` genre + `50%` release date"))
			}
			.font(.footnote)
			.fontDesign(.serif)
			.foregroundStyle(.secondary)
		}
	}

	// MARK: - Energy section

	private var energySection: some View {
		VStack(alignment: .leading, spacing: 16) {
			sectionHeading("Energy")

			body(Text("Every song gets an energy score from 0 to 1. The four bands you can filter by — Glacial, Mellow, Energetic, Intense — are named stretches of that one axis, not separate buckets."))

			VStack(spacing: 8) {
				EnergyScale()
				body(Text("Same band: a 72-BPM electronic track reads Mellow, a 134-BPM one Energetic."))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			.padding(.vertical, 8)

			body(Text("Two signals set the score. A coarse **band** comes first — from the audio fingerprint matched against hand-picked reference tracks, or from genre alone before a song is fingerprinted — fixing a starting point at the band’s centre. Then **tempo** floats the song off that centre, so two tracks in one band needn’t share a score."))

			VStack(alignment: .leading, spacing: 6) {
				bullet(Text("`energy = 0.7 × band centre + 0.3 × tempo`"))
				bullet(Text("Tempo maps `60 BPM → 0`, `160 BPM → 1`"))
				bullet(Text("No tempo detected → the song sits on its band’s centre"))
				bullet(Text("No band — no fingerprint, unrecognised genre — leaves a song unscored, skipped by energy filters"))
			}
			.font(.footnote)
			.fontDesign(.serif)
			.foregroundStyle(.secondary)

			body(Text("The Songs tab’s energy filter and the Design tab’s energy curve both read this score. The curve fills each slot with the song nearest its height, so a line drawn from calm to intense plays back as a real arc, not four plateaus."))
		}
	}

	// MARK: - Building blocks

	private func sectionHeading(_ title: String) -> some View {
		Text(title)
			.font(.title3)
			.fontWeight(.semibold)
	}

	/// Serif body text — markdown-aware so inline backticks render as code.
	private func body(_ text: Text) -> some View {
		text
			.fontDesign(.serif)
	}

	private func bullet(_ text: Text) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("•")
			text
		}
		.fontDesign(.default)
	}
}

// MARK: - Funnel visualization

private struct SongFunnel: View {
	var body: some View {
		VStack(spacing: 0) {
			stage("Library", count: "~8,000", width: 240, tint: .gray)
			connector("three parallel fetches")
			HStack(spacing: 8) {
				stage("Most played", count: "\(GemDeckBuilder.basePoolSize)", width: 90, tint: .blue)
				stage("Oldest", count: "\(GemDeckBuilder.basePoolSize)", width: 90, tint: .purple)
				stage("Newest", count: "\(GemDeckBuilder.basePoolSize)", width: 90, tint: .pink)
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 8)
			.background(
				RoundedRectangle(cornerRadius: 24).fill(.quinary)
			)
			connector("union + dedupe")
			stage("Candidates", count: "~2,500", width: 200, tint: .gray.opacity(0.7))
			connector("score, cap per artist & album")
			stage("In rotation", count: "\(GemDeckBuilder.deckSize)", width: 120, tint: .black)
		}
	}

	private func stage(_ name: String, count: String, width: Double, tint: Color) -> some View {
		VStack(spacing: 4) {
			Capsule()
				.fill(tint)
				.frame(width: width, height: 32)
				.overlay {
					Text(count)
						.font(.system(.footnote, design: .monospaced))
						.fontWeight(.semibold)
						.foregroundStyle(.white)
				}
			Text(name)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
	}

	private func connector(_ label: String) -> some View {
		VStack(spacing: 0) {
			Rectangle()
				.fill(.tertiary)
				.frame(width: 1, height: 12)
			Text(label)
				.font(.caption2)
				.foregroundStyle(.secondary)
				.italic()
			Rectangle()
				.fill(.tertiary)
				.frame(width: 1, height: 12)
		}
		.padding(.vertical, 4)
	}
}

// MARK: - Energy scale visualization

/// The continuous energy axis (0 → 1) as both legend and worked example.
/// The track is the app-wide energy gradient with each band tint pinned at
/// its `centerValue`, so a dot's position colour-matches the scale beneath
/// it. Two same-band tracks placed at their *real* `SongEnergy.value` show
/// tempo floating songs off the shared band centre — slow drops toward
/// Mellow, fast climbs into Energetic.
private struct EnergyScale: View {
	/// Same band (Energetic), split only by tempo. Energies come straight
	/// from `SongEnergy.value` so the dots can't drift from the real model.
	private var examples: [(bpm: Int, energy: Double)] {
		[72, 134].map { bpm in
			(bpm, SongEnergy.value(band: .energetic, bpm: Double(bpm)) ?? 0.5)
		}
	}

	private var trackGradient: Gradient {
		Gradient(stops: EnergyBand.concreteOrdered.map { band in
			.init(color: band.tint, location: band.centerValue)
		})
	}

	var body: some View {
		GeometryReader { geo in
			let w = geo.size.width
			let labelY = 8.0
			let trackY = 30.0
			let bandY = 54.0

			ZStack(alignment: .topLeading) {
				RoundedRectangle(cornerRadius: 7)
					.fill(LinearGradient(gradient: trackGradient, startPoint: .leading, endPoint: .trailing))
					.frame(height: 14)
					.position(x: w / 2, y: trackY)

				ForEach(examples, id: \.bpm) { example in
					let x = example.energy * w

					Text("\(example.bpm) BPM")
						.font(.caption2)
						.monospacedDigit()
						.foregroundStyle(.secondary)
						.fixedSize()
						.position(x: x, y: labelY)

					Circle()
						.fill(.white)
						.frame(width: 11, height: 11)
						.overlay(Circle().strokeBorder(.black.opacity(0.12)))
						.shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
						.position(x: x, y: trackY)
				}

				ForEach(EnergyBand.concreteOrdered) { band in
					Text(band.displayName)
						.font(.caption2)
						.foregroundStyle(.secondary)
						.fixedSize()
						.position(x: band.centerValue * w, y: bandY)
				}
			}
		}
		.frame(height: 64)
	}
}

#Preview {
	HowItWorksView()
}
