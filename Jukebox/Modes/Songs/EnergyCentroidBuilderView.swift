//
//  EnergyCentroidBuilderView.swift
//  Jukebox
//
//  Created by Daniel Eden on 22/05/2026.
//
//  Debug-only generator that resolves each anchor album in
//  EnergyAnchors.json against the Apple Music catalog, embeds a
//  capped number of tracks via AudioFeaturePrint, mean-pools them
//  per band, and writes the resulting per-band centroid + threshold
//  to a JSON file in Documents. Surfaces a share sheet so the user
//  can pull the file out and drop it into Resources as
//  EnergyCentroids.json before committing.
//
//  Heavy: ~22 anchor albums × up to 8 tracks each = ~176 30-second
//  preview downloads + ML passes on first run (cached afterwards).
//  Run on wifi; expect several minutes.
//

#if DEBUG

	import MusicKit
	import SwiftUI

	struct EnergyCentroidBuilderView: View {
		@Environment(\.dismiss) private var dismiss
		@State private var phase: Phase = .idle
		@State private var outputURL: URL?

		/// Cap on tracks pulled from each anchor album. The first N tracks
		/// usually span the album's range well enough — pooling more just
		/// adds embedding cost without meaningful centroid movement.
		private static let tracksPerAlbum = 8

		var body: some View {
			NavigationStack {
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						switch phase {
						case .idle:
							Text("Tap Build to start. This downloads a 30-second preview for each anchor track and runs Apple's AudioFeaturePrint extractor against it — expect a few minutes on wifi.")
								.foregroundStyle(.secondary)
							Button("Build centroids") {
								Task { await run() }
							}
							.buttonStyle(.borderedProminent)

						case let .running(progress):
							HStack {
								ProgressView(value: progress.fraction)
								Text("\(progress.done)/\(progress.total)")
									.font(.system(.caption, design: .monospaced))
									.foregroundStyle(.secondary)
							}
							if let current = progress.currentLabel {
								Text(current)
									.font(.caption)
									.foregroundStyle(.secondary)
									.lineLimit(2)
							}
							if !progress.warnings.isEmpty {
								Divider()
								Text("Skipped (\(progress.warnings.count))")
									.font(.caption).foregroundStyle(.orange)
								ForEach(Array(progress.warnings.enumerated()), id: \.offset) { _, w in
									Text(w).font(.caption).foregroundStyle(.secondary)
								}
							}

						case let .done(report):
							reportView(report)

						case let .failed(message):
							Text(message).foregroundStyle(.red)
							Button("Retry") {
								Task { await run() }
							}
						}
					}
					.padding()
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.navigationTitle("Energy centroids")
				.inlineNavigationTitle()
				.toolbar {
					ToolbarItem(placement: .trailingAction) {
						Button("Done") { dismiss() }
					}
				}
			}
		}

		private func reportView(_ r: Report) -> some View {
			let grouped = Dictionary(grouping: r.bands, by: \.band)
				.sorted { $0.key < $1.key }
			return VStack(alignment: .leading, spacing: 16) {
				Text("Generated \(r.bands.count) sub-style centroid\(r.bands.count == 1 ? "" : "s") across \(grouped.count) band\(grouped.count == 1 ? "" : "s")")
					.font(.headline)

				ForEach(grouped, id: \.key) { band, subStyles in
					VStack(alignment: .leading, spacing: 4) {
						Text(band.capitalized).font(.subheadline)
						ForEach(subStyles.sorted { $0.subStyle < $1.subStyle }) { sub in
							Text("· \(sub.subStyle): \(sub.trackCount) tracks · \(sub.albumCount) albums · threshold \(String(format: "%.3f", sub.threshold))")
								.font(.caption).foregroundStyle(.secondary)
						}
					}
				}

				if !r.warnings.isEmpty {
					Divider()
					Text("Warnings (\(r.warnings.count))")
						.font(.caption).foregroundStyle(.orange)
					ForEach(Array(r.warnings.enumerated()), id: \.offset) { _, w in
						Text(w).font(.caption).foregroundStyle(.secondary)
					}
				}

				Divider()
				if let url = outputURL {
					Text("Wrote: \(url.path)").font(.caption).foregroundStyle(.secondary)
					ShareLink(item: url) {
						Label("Share / save centroids", systemImage: "square.and.arrow.up")
					}
					.buttonStyle(.borderedProminent)
					Text("Save this file, name it EnergyCentroids.json, drop it in Jukebox/Modes/Songs/, and commit.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}

		// MARK: - Run

		private func run() async {
			// 1. Authorize MusicKit.
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

			// 2. Load anchors from the bundled manifest.
			let anchors = EnergyCentroidsLoader.loadAnchors()
			guard !anchors.isEmpty else {
				phase = .failed("Couldn't load EnergyAnchors.json from the bundle.")
				return
			}

			// 3. Resolve each anchor album → catalog Album → up-to-N tracks.
			//    Group results by (band, subStyle) so the centroid step can
			//    pool per sub-style — see EnergyCentroids.swift for why
			//    single-centroid pooling failed for heterogeneous bands.
			phase = .running(.init(done: 0, total: anchors.count, currentLabel: "Resolving albums…", warnings: []))

			var tracksByKey: [GroupKey: [Song]] = [:]
			var albumCountByKey: [GroupKey: Int] = [:]
			var warnings: [String] = []

			for (idx, anchor) in anchors.enumerated() {
				phase = .running(.init(
					done: idx,
					total: anchors.count,
					currentLabel: "Resolving \(anchor.artist) — \(anchor.album)",
					warnings: warnings
				))
				do {
					let tracks = try await resolveTracks(for: anchor, limit: Self.tracksPerAlbum)
					if tracks.isEmpty {
						warnings.append("No tracks resolved for \(anchor.artist) — \(anchor.album)")
						continue
					}
					let key = GroupKey(band: anchor.band, subStyle: anchor.subStyle)
					tracksByKey[key, default: []].append(contentsOf: tracks)
					albumCountByKey[key, default: 0] += 1
				} catch {
					warnings.append("\(anchor.artist) — \(anchor.album): \(error.localizedDescription)")
				}
			}

			// 4. Embed every track. Total work = sum of tracks across all
			//    groups; per-track cache hits cost ~milliseconds, misses
			//    cost ~seconds. Skip-on-failure so one broken preview
			//    doesn't sink the whole build.
			let totalTracks = tracksByKey.values.reduce(0) { $0 + $1.count }
			guard totalTracks > 0 else {
				phase = .failed("Resolved zero tracks across all anchor albums. Check warnings above.")
				return
			}

			var embeddingsByKey: [GroupKey: [[Float]]] = [:]
			var done = 0
			for (key, tracks) in tracksByKey {
				for track in tracks {
					phase = .running(.init(
						done: done,
						total: totalTracks,
						currentLabel: "Embedding \(track.title) — \(track.artistName)",
						warnings: warnings
					))
					do {
						let vec = try await AudioEmbeddingService.embed(song: track)
						embeddingsByKey[key, default: []].append(vec)
					} catch {
						warnings.append("Embed failed: \(track.title) — \(track.artistName): \(error.localizedDescription)")
					}
					done += 1
				}
			}

			// 5. Per-(band, subStyle) centroid + median threshold, then
			//    bucket into per-band lists of sub-style payloads.
			var bandsOut: [String: [EnergyCentroidPayload]] = [:]
			var summaries: [Report.BandSummary] = []
			for (key, vectors) in embeddingsByKey {
				guard !vectors.isEmpty else { continue }
				let centroid = meanVector(vectors)
				guard !centroid.isEmpty else { continue }
				let cosines = vectors.map { AudioEmbeddingService.cosineSimilarity($0, centroid) }
				let threshold = median(cosines)
				let payload = EnergyCentroidPayload(
					band: key.band,
					subStyle: key.subStyle,
					centroid: centroid,
					threshold: threshold,
					trackCount: vectors.count,
					albumCount: albumCountByKey[key] ?? 0
				)
				bandsOut[key.band, default: []].append(payload)
				summaries.append(.init(
					band: key.band,
					subStyle: key.subStyle,
					trackCount: payload.trackCount,
					albumCount: payload.albumCount,
					threshold: payload.threshold
				))
			}
			// Stable sort within each band for diff-friendly JSON output.
			for band in bandsOut.keys {
				bandsOut[band]?.sort { $0.subStyle < $1.subStyle }
			}

			// 6. Write the bundle JSON to Documents.
			let bundle = EnergyCentroidBundle(bands: bandsOut)
			let url: URL
			do {
				url = try writeBundle(bundle)
			} catch {
				phase = .failed("Couldn't write centroids file: \(error.localizedDescription)")
				return
			}

			outputURL = url
			phase = .done(Report(bands: summaries.sorted { $0.band < $1.band }, warnings: warnings))
		}

		private func resolveTracks(for anchor: EnergyAnchor, limit: Int) async throws -> [Song] {
			// Search the catalog for the album. `Album.title` matching is
			// loose — Apple does substring + fuzz on its end — so we
			// constrain by artist after the fact.
			let term = "\(anchor.album) \(anchor.artist)"
			let request = MusicCatalogSearchRequest(term: term, types: [Album.self])
			let response = try await request.response()

			let needle = anchor.artist.lowercased()
			let albumTitleNeedle = normalised(anchor.album)
			let candidates = response.albums.prefix(10)
			for candidate in candidates {
				let artistMatch = candidate.artistName.lowercased().contains(needle)
					|| needle.contains(candidate.artistName.lowercased())
				let titleMatch = normalised(candidate.title) == albumTitleNeedle
					|| normalised(candidate.title).contains(albumTitleNeedle)
					|| albumTitleNeedle.contains(normalised(candidate.title))
				guard artistMatch, titleMatch else { continue }

				let detailed = try await candidate.with([.tracks])
				let tracks = (detailed.tracks ?? [])
					.compactMap { track -> Song? in
						if case let .song(song) = track { return song }
						return nil
					}
				return Array(tracks.prefix(limit))
			}
			return []
		}

		/// Light normaliser: lowercase + strip punctuation so "Music for
		/// Saxofone & Bass Guitar" matches "Music for Saxofone and Bass
		/// Guitar" and "DJ-Kicks (Moodymann)" matches "DJ Kicks Moodymann".
		private func normalised(_ s: String) -> String {
			s.lowercased()
				.replacingOccurrences(of: "&", with: "and")
				.components(separatedBy: CharacterSet.alphanumerics.inverted)
				.filter { !$0.isEmpty }
				.joined(separator: " ")
		}

		private func meanVector(_ vectors: [[Float]]) -> [Float] {
			guard let first = vectors.first, !first.isEmpty else { return [] }
			let dims = first.count
			var sum = [Float](repeating: 0, count: dims)
			var counted: Float = 0
			for v in vectors where v.count == dims {
				for i in 0 ..< dims {
					sum[i] += v[i]
				}
				counted += 1
			}
			guard counted > 0 else { return [] }
			for i in 0 ..< dims {
				sum[i] /= counted
			}
			return sum
		}

		private func median(_ values: [Float]) -> Float {
			guard !values.isEmpty else { return 0 }
			let sorted = values.sorted()
			let mid = sorted.count / 2
			if sorted.count.isMultiple(of: 2) {
				return (sorted[mid - 1] + sorted[mid]) / 2
			}
			return sorted[mid]
		}

		private func writeBundle(_ bundle: EnergyCentroidBundle) throws -> URL {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			let data = try encoder.encode(bundle)
			let docs = try FileManager.default.url(
				for: .documentDirectory,
				in: .userDomainMask,
				appropriateFor: nil,
				create: true
			)
			let url = docs.appendingPathComponent("EnergyCentroids.json")
			try data.write(to: url, options: .atomic)
			return url
		}
	}

	// MARK: - Types

	private extension EnergyCentroidBuilderView {
		enum Phase {
			case idle
			case running(Progress)
			case done(Report)
			case failed(String)
		}

		struct Progress {
			let done: Int
			let total: Int
			let currentLabel: String?
			let warnings: [String]

			var fraction: Double {
				guard total > 0 else { return 0 }
				return Double(done) / Double(total)
			}
		}

		struct Report {
			let bands: [BandSummary]
			let warnings: [String]

			struct BandSummary: Identifiable {
				let band: String
				let subStyle: String
				let trackCount: Int
				let albumCount: Int
				let threshold: Float
				var id: String {
					"\(band)/\(subStyle)"
				}
			}
		}

		struct GroupKey: Hashable {
			let band: String
			let subStyle: String
		}
	}

#endif
