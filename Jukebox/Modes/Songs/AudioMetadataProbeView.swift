//
//  AudioMetadataProbeView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Temporary diagnostic: enumerates the user's local MPMediaLibrary and
//  reports how many songs have a non-zero `beatsPerMinute`, how many
//  have a local `assetURL` (i.e. are owned files we could DSP-analyze),
//  and how many have a non-empty genre. The point is to find out — on
//  a real library — whether a BPM/key-driven flow is even feasible
//  before designing the algorithm. MusicKit's `Song` exposes no audio-
//  analysis fields at all; `MPMediaItem.beatsPerMinute` is the only
//  tempo-ish public surface and Apple does not populate it for streaming
//  catalog metadata, so coverage in practice is usually near-zero.

import MediaPlayer
import SwiftUI

struct AudioMetadataProbeView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var phase: Phase = .idle

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					switch phase {
					case .idle:
						Text("Probing your library for tempo and metadata coverage…")
							.foregroundStyle(.secondary)
					case .needsAuth:
						authPrompt
					case let .running(scanned):
						HStack {
							ProgressView()
							Text("Scanned \(scanned) songs…")
						}
					case let .done(report):
						reportView(report)
					case let .failed(message):
						Text(message)
							.foregroundStyle(.red)
					}
				}
				.padding()
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.navigationTitle("Audio Metadata Probe")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
			.task { await run() }
		}
	}

	private var authPrompt: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("This probe reads tempo metadata via the Media Library framework, which needs its own permission (separate from MusicKit).")
				.foregroundStyle(.secondary)
			Button("Grant Access") {
				Task {
					let status = await MPMediaLibrary.requestAuthorization()
					if status == .authorized { await run() }
				}
			}
			.buttonStyle(.borderedProminent)
		}
	}

	private func reportView(_ r: Report) -> some View {
		VStack(alignment: .leading, spacing: 20) {
			Group {
				stat("Total library songs", "\(r.totalSongs)")
				stat("With BPM (> 0)", "\(r.bpmPopulated) (\(percent(r.bpmPopulated, of: r.totalSongs)))")
				stat("With assetURL (locally owned)", "\(r.localAssets) (\(percent(r.localAssets, of: r.totalSongs)))")
				stat("With genre", "\(r.withGenre) (\(percent(r.withGenre, of: r.totalSongs)))")
			}

			if !r.bpmHistogram.isEmpty {
				Divider()
				Text("BPM distribution (populated subset)")
					.font(.headline)
				ForEach(r.bpmHistogram) { bucket in
					HStack {
						Text(bucket.label).font(.system(.body, design: .monospaced))
						Spacer()
						Text("\(bucket.count)").font(.system(.body, design: .monospaced))
					}
				}
			}

			if !r.examples.isEmpty {
				Divider()
				Text("Examples with BPM")
					.font(.headline)
				ForEach(r.examples) { ex in
					HStack {
						VStack(alignment: .leading) {
							Text(ex.title).font(.subheadline)
							Text(ex.artist).font(.caption).foregroundStyle(.secondary)
						}
						Spacer()
						Text("\(ex.bpm) bpm").font(.system(.body, design: .monospaced))
					}
				}
			}
		}
	}

	private func stat(_ label: String, _ value: String) -> some View {
		HStack {
			Text(label).foregroundStyle(.secondary)
			Spacer()
			Text(value).fontWeight(.semibold)
		}
	}

	private func percent(_ n: Int, of total: Int) -> String {
		guard total > 0 else { return "0%" }
		return String(format: "%.1f%%", Double(n) / Double(total) * 100)
	}

	// MARK: - Probe

	private func run() async {
		let status = MPMediaLibrary.authorizationStatus()
		if status == .notDetermined {
			phase = .needsAuth
			return
		}
		guard status == .authorized else {
			phase = .failed("Media Library access denied. Enable it in Settings → Privacy → Media & Apple Music → Jukebox.")
			return
		}

		phase = .running(scanned: 0)

		let report = await Task.detached(priority: .userInitiated) { () -> Report in
			let query = MPMediaQuery.songs()
			let items = query.items ?? []
			let total = items.count

			var bpmPopulated = 0
			var localAssets = 0
			var withGenre = 0
			var examples: [Example] = []

			// Six buckets covering the practical BPM range; "outside" catches
			// anything weird (very slow ballads, very fast electronic, or
			// mistagged values).
			var counts = [0, 0, 0, 0, 0, 0, 0]

			for item in items {
				if item.assetURL != nil { localAssets += 1 }
				if let g = item.genre, !g.isEmpty { withGenre += 1 }
				let bpm = item.beatsPerMinute
				if bpm > 0 {
					bpmPopulated += 1
					switch bpm {
					case 0 ..< 60: counts[0] += 1
					case 60 ..< 90: counts[1] += 1
					case 90 ..< 110: counts[2] += 1
					case 110 ..< 130: counts[3] += 1
					case 130 ..< 150: counts[4] += 1
					case 150 ..< 180: counts[5] += 1
					default: counts[6] += 1
					}
					if examples.count < 8 {
						examples.append(Example(
							title: item.title ?? "Unknown",
							artist: item.artist ?? "Unknown",
							bpm: bpm
						))
					}
				}
			}

			let labels = ["< 60", "60–89", "90–109", "110–129", "130–149", "150–179", "180+"]
			let histogram = zip(labels, counts).map { Bucket(label: $0.0, count: $0.1) }

			return Report(
				totalSongs: total,
				bpmPopulated: bpmPopulated,
				localAssets: localAssets,
				withGenre: withGenre,
				bpmHistogram: histogram.filter { $0.count > 0 },
				examples: examples
			)
		}.value

		phase = .done(report)
	}
}

// MARK: - Types

private extension AudioMetadataProbeView {
	enum Phase {
		case idle
		case needsAuth
		case running(scanned: Int)
		case done(Report)
		case failed(String)
	}

	struct Report {
		let totalSongs: Int
		let bpmPopulated: Int
		let localAssets: Int
		let withGenre: Int
		let bpmHistogram: [Bucket]
		let examples: [Example]
	}

	struct Bucket: Identifiable {
		var id: String {
			label
		}

		let label: String
		let count: Int
	}

	struct Example: Identifiable {
		let id = UUID()
		let title: String
		let artist: String
		let bpm: Int
	}
}
