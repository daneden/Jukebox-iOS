//
//  EmbeddingSpikeView.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//
//  Spike harness for AudioEmbeddingService. Pulls a small sample of songs
//  from the user's library (the gem-deck head), embeds each via Apple's
//  AudioFeaturePrint extractor, and shows a pairwise cosine-similarity
//  matrix. The whole point is to eyeball the result: do tracks that
//  *should* sound similar (same artist, same genre, same era) land closer
//  to each other than tracks that shouldn't? If yes, the embedding signal
//  is real and we can build the dial-flow on it. If not, we need a
//  music-specialized model (CLAP) before going further.
//
//  Debug-only: gated behind `#if DEBUG` so it doesn't ship into
//  release builds. The Settings menu only surfaces it in debug too.

#if DEBUG

	import MusicKit
	import SwiftUI

	struct EmbeddingSpikeView: View {
		@Environment(\.dismiss) private var dismiss
		@State private var phase: Phase = .idle

		private static let sampleCount = 5

		var body: some View {
			NavigationStack {
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						switch phase {
						case .idle:
							Text("Preparing sample…").foregroundStyle(.secondary)

						case let .running(progress):
							HStack {
								ProgressView()
								Text("Embedding \(progress.done) of \(progress.total)…")
							}
							if let current = progress.currentTitle {
								Text(current).font(.caption).foregroundStyle(.secondary)
							}

						case let .done(report):
							reportView(report)

						case let .failed(message):
							Text(message).foregroundStyle(.red)
						}
					}
					.padding()
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.navigationTitle("Embedding Spike")
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .topBarTrailing) {
						Button("Done") { dismiss() }
					}
				}
				.task { await run() }
			}
		}

		private func reportView(_ r: Report) -> some View {
			VStack(alignment: .leading, spacing: 20) {
				Text("Embedded \(r.songs.count) songs · dim = \(r.embeddingDim)")
					.font(.headline)

				Divider()
				Text("Songs").font(.subheadline).foregroundStyle(.secondary)
				ForEach(Array(r.songs.enumerated()), id: \.offset) { idx, song in
					HStack(alignment: .top) {
						Text("\(idx + 1)")
							.font(.system(.body, design: .monospaced))
							.frame(width: 24, alignment: .leading)
						VStack(alignment: .leading) {
							Text(song.title).font(.body)
							Text(song.artist).font(.caption).foregroundStyle(.secondary)
						}
					}
				}

				Divider()
				Text("Pairwise similarity (cosine)").font(.subheadline).foregroundStyle(.secondary)
				ForEach(r.pairs) { pair in
					HStack {
						Text("\(pair.a + 1)·\(pair.b + 1)")
							.font(.system(.body, design: .monospaced))
							.frame(width: 36, alignment: .leading)
						Text(String(format: "%.3f", pair.similarity))
							.font(.system(.body, design: .monospaced))
							.foregroundStyle(color(for: pair.similarity))
							.frame(width: 64, alignment: .leading)
						Text(pair.label).font(.caption).foregroundStyle(.secondary)
					}
				}

				Divider()
				Text("Most similar pair: \(r.mostSimilar.label) (\(String(format: "%.3f", r.mostSimilar.similarity)))")
					.font(.footnote)
				Text("Least similar pair: \(r.leastSimilar.label) (\(String(format: "%.3f", r.leastSimilar.similarity)))")
					.font(.footnote)
			}
		}

		private func color(for similarity: Float) -> Color {
			switch similarity {
			case 0.95...: .green
			case 0.85 ..< 0.95: .mint
			case 0.70 ..< 0.85: .primary
			case 0.50 ..< 0.70: .orange
			default: .red
			}
		}

		// MARK: - Run

		private func run() async {
			// 1. Authorize MusicKit if needed.
			let status = MusicAuthorization.currentStatus
			if status == .notDetermined {
				let newStatus = await MusicAuthorization.request()
				if newStatus != .authorized {
					phase = .failed("MusicKit access required.")
					return
				}
			} else if status != .authorized {
				phase = .failed("MusicKit access denied. Enable it in Settings.")
				return
			}

			// 2. Fetch a small sample. Top of the gem deck gives us songs the
			//    user has some history with, which makes the "is this signal real"
			//    eyeball test more meaningful than random catalog picks.
			let songs: [Song]
			do {
				let result = try await GemDeckBuilder.build()
				songs = Array(result.deck.prefix(Self.sampleCount))
			} catch {
				phase = .failed("Couldn't build a sample deck: \(error.localizedDescription)")
				return
			}
			guard !songs.isEmpty else {
				phase = .failed("Gem deck came back empty.")
				return
			}

			phase = .running(.init(done: 0, total: songs.count, currentTitle: nil))

			// 3. Embed each.
			var embeddings: [[Float]] = []
			var entries: [Report.SongEntry] = []
			for (idx, song) in songs.enumerated() {
				phase = .running(.init(
					done: idx,
					total: songs.count,
					currentTitle: "\(song.title) — \(song.artistName)"
				))
				do {
					let vec = try await AudioEmbeddingService.embed(song: song)
					embeddings.append(vec)
					entries.append(.init(title: song.title, artist: song.artistName))
				} catch {
					phase = .failed("Embedding failed at #\(idx + 1) (\(song.title)): \(error.localizedDescription)")
					return
				}
			}

			// 4. Pairwise similarities.
			var pairs: [Report.Pair] = []
			for i in 0 ..< embeddings.count {
				for j in (i + 1) ..< embeddings.count {
					let sim = AudioEmbeddingService.cosineSimilarity(embeddings[i], embeddings[j])
					pairs.append(.init(
						a: i,
						b: j,
						similarity: sim,
						label: "\(entries[i].title) vs \(entries[j].title)"
					))
				}
			}
			let sortedPairs = pairs.sorted { $0.similarity > $1.similarity }

			phase = .done(Report(
				songs: entries,
				embeddingDim: embeddings.first?.count ?? 0,
				pairs: pairs,
				mostSimilar: sortedPairs.first!,
				leastSimilar: sortedPairs.last!
			))
		}
	}

	// MARK: - Types

	private extension EmbeddingSpikeView {
		enum Phase {
			case idle
			case running(Progress)
			case done(Report)
			case failed(String)
		}

		struct Progress {
			let done: Int
			let total: Int
			let currentTitle: String?
		}

		struct Report {
			let songs: [SongEntry]
			let embeddingDim: Int
			let pairs: [Pair]
			let mostSimilar: Pair
			let leastSimilar: Pair

			struct SongEntry {
				let title: String
				let artist: String
			}

			struct Pair: Identifiable {
				let id = UUID()
				let a: Int
				let b: Int
				let similarity: Float
				let label: String
			}
		}
	}

#endif
