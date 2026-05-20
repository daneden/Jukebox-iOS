//
//  HowItWorksView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  A "show your work" surface for the curious user. Walks through the
//  three under-the-hood stages that produce what's on the dial: the
//  funnel from the full library down to the 300-song gem deck, the
//  similarity walk that orders the deck into a coherent path, and the
//  audio embedding cache that powers the similarity signal.
//
//  Designed as a growth surface — sections are independent so future
//  additions (cluster maps from #12, per-cluster intensity bands, etc.)
//  slot in cleanly without re-flowing the existing copy.

import SwiftUI

struct HowItWorksView: View {
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 32) {
					intro
					gemDeckSection
					walkSection
					embeddingSection
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 16)
			}
			.navigationTitle("How It Works")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
		}
	}

	// MARK: - Intro

	private var intro: some View {
		Text("Jukebox surfaces songs you've forgotten you love. Here's the path from your library to what's on the dial.")
			.font(.callout)
			.foregroundStyle(.secondary)
	}

	// MARK: - Gem deck section

	private var gemDeckSection: some View {
		VStack(alignment: .leading, spacing: 16) {
			sectionHeading("Finding the gems")

			GemDeckFunnel()
				.padding(.vertical, 8)

			Text("Two complementary pools — songs you used to play a lot, and songs you saved long ago but barely touched. Together they cover both \"lost favorites\" and \"never quite gave them a chance.\"")

			VStack(alignment: .leading, spacing: 6) {
				bullet("Nostalgia score: log(plays + 1) × months dormant")
				bullet("Discovery score: months in library ÷ (plays + 1)")
				bullet("Blended 70% nostalgia + 30% discovery")
				bullet("Songs played in the last 14 days are filtered out")
			}
			.font(.footnote)
			.foregroundStyle(.secondary)
		}
	}

	// MARK: - Walk section

	private var walkSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeading("Walking the dial")

			Text("The 300 deck songs are ordered into a path where consecutive entries share sonic mood. Each step picks the next song with highest similarity to the previous, subject to:")

			VStack(alignment: .leading, spacing: 6) {
				bullet("No same artist within the previous 2 songs")
				bullet("No same album within the previous 3 songs")
			}
			.font(.footnote)
			.foregroundStyle(.secondary)

			Text("The starting song is picked from the top \(SongDeckWalk.seedTier) by gem score, rotated per session so different cold starts feel different.")
		}
	}

	// MARK: - Embedding section

	private var embeddingSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeading("Audio fingerprints")

			Text("Each song's audio is fingerprinted from its 30-second preview using Apple's built-in audio analyzer. The 512-number vector captures the song's sonic texture and is cached locally on your device.")

			Text("Cosine similarity between two vectors tells the walk how alike two songs sound. That signal is blended with genre overlap and release-date proximity:")

			VStack(alignment: .leading, spacing: 6) {
				bullet("50% audio fingerprint similarity")
				bullet("30% genre overlap")
				bullet("20% release date proximity")
			}
			.font(.footnote)
			.foregroundStyle(.secondary)

			Text("Fingerprints are computed in the background as the deck builds; the toolbar indicator shows progress.")
		}
	}

	// MARK: - Building blocks

	private func sectionHeading(_ title: String) -> some View {
		Text(title)
			.font(.title3)
			.fontWeight(.semibold)
	}

	private func bullet(_ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Text("·")
			Text(text)
		}
	}
}

// MARK: - Funnel visualization

private struct GemDeckFunnel: View {
	var body: some View {
		VStack(spacing: 0) {
			stage("Library", count: "~8,000", width: 240, tint: .secondary.opacity(0.4))
			connector("fetch top 1,500 by play count and oldest by add date")
			HStack(spacing: 16) {
				stage("Most played", count: "1,500", width: 120, tint: .blue.opacity(0.6))
				stage("Oldest", count: "1,500", width: 120, tint: .purple.opacity(0.6))
			}
			connector("union + dedupe")
			stage("Candidates", count: "~2,500", width: 200, tint: .accentColor.opacity(0.4))
			connector("score + recency filter")
			stage("Deck", count: "300", width: 100, tint: .accentColor)
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

#Preview {
	HowItWorksView()
}
