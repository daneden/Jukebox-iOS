//
//  PlaylistCoverArt.swift
//  Jukebox
//
//  Created by Daniel Eden on 24/05/2026.
//
//  Generated cover art for a history playlist — title over a mesh gradient
//  sampled from album thumbnails. Same view drives both the in-app preview
//  and the 1024×1024 share PNG.
//
//  MusicKit's `createPlaylist` doesn't accept cover art
//  (`project-musickit-no-artwork`), so applying it is a manual share/save flow.

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import ImageIO
import MusicKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - View

/// Square playlist cover. Internal sizing is proportional to `size` so it
/// renders identically at 280pt (preview) and 1024pt (export).
struct PlaylistCoverArt: View {
	let title: String
	/// Up to four base colors cycled across the mesh; nil = neutral fallback.
	let palette: [Color]?
	/// Deterministic mesh-layout seed — same value, same gradient.
	var seed: UInt64 = 0
	var size: CGFloat = 280
	/// The exported PNG passes `false` for sharp corners — downstream
	/// pickers apply their own rounding, and a pre-rounded bitmap shows
	/// transparent corners against any backdrop.
	var rounded: Bool = true

	private var basePalette: [Color] {
		guard let palette, !palette.isEmpty else {
			return PlaylistCoverPalette.fallback
		}
		return (0 ..< 4).map { palette[$0 % palette.count] }
	}

	/// `0` is treated as unseeded and pinned to a fixed value, so the Xcode
	/// preview canvas doesn't reroll on every redraw.
	private var effectiveSeed: UInt64 {
		seed == 0 ? 0xC0FFEE : seed
	}

	/// 3×3 mesh: corners pinned, edge midpoints kept on their edge so the
	/// mesh covers the canvas. Free coords stay in the middle band — letting
	/// a point near a pinned corner collapses its quad into a sliver, which
	/// compresses a color transition into a sharp, broken-looking edge.
	private var meshPoints: [SIMD2<Float>] {
		var rng = SeededGenerator(seed: effectiveSeed)
		let topMid = SIMD2<Float>(unit(&rng), 0.0)
		let leftMid = SIMD2<Float>(0.0, unit(&rng))
		let center = SIMD2<Float>(unit(&rng), unit(&rng))
		let rightMid = SIMD2<Float>(1.0, unit(&rng))
		let bottomMid = SIMD2<Float>(unit(&rng), 1.0)
		return [
			[0.0, 0.0], topMid, [1.0, 0.0],
			leftMid, center, rightMid,
			[0.0, 1.0], bottomMid, [1.0, 1.0],
		]
	}

	/// Seeded uniform sample in the safe middle band [0.20, 0.80] — see
	/// `meshPoints` for why the corners are avoided.
	private func unit(_ rng: inout SeededGenerator) -> Float {
		let raw = Float(rng.next() >> 11) / Float(UInt64(1) << 53)
		return 0.20 + raw * 0.60
	}

	/// Non-breaking the final space binds the last two words, avoiding a
	/// single-word last line (a "widow").
	private static func bondedLastWord(of string: String) -> String {
		guard let lastSpace = string.lastIndex(of: " ") else { return string }
		var result = string
		result.replaceSubrange(lastSpace ... lastSpace, with: "\u{00A0}")
		return result
	}

	/// Seed-shuffled palette cycled over the mesh in a pattern that avoids
	/// the same entry in adjacent cells, so the blend has texture.
	private var meshColors: [Color] {
		var rng = SeededGenerator(seed: effectiveSeed &+ 0x9E37)
		let shuffled = basePalette.shuffled(using: &rng)
		let pattern = [0, 2, 1,
		               3, 0, 2,
		               1, 3, 0]
		return pattern.map { shuffled[$0 % shuffled.count] }
	}

	var body: some View {
		ZStack {
			MeshGradient(
				width: 3,
				height: 3,
				points: meshPoints,
				colors: meshColors
			)

			// Inner shading keeps the title readable on light palettes.
			LinearGradient(
				colors: [.black.opacity(0.15), .black.opacity(0)],
				startPoint: .top,
				endPoint: .bottom
			)
			.blendMode(.plusDarker)

			Text(Self.bondedLastWord(of: title))
				.font(.system(size: size * 0.10, weight: .semibold, design: .default).leading(.tight))
				.lineLimit(5)
				.minimumScaleFactor(0.5)
				.foregroundStyle(.white)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.padding(size * 0.075)

			VStack(spacing: 0) {
				Spacer(minLength: 0)
				HStack(spacing: 0) {
					Spacer(minLength: 0)
					Image(.playback)
						.resizable()
						.renderingMode(.template)
						.aspectRatio(contentMode: .fit)
						.frame(width: size * 0.135)
						.foregroundStyle(.white.opacity(0.9))
				}
			}
			.padding(size * 0.065)
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: rounded ? size * 0.045 : 0))
		.compositingGroup()
	}
}

// MARK: - Seeded RNG

/// SplitMix64. Deterministic per-playlist randomness so the preview,
/// the PNG, and any re-render land on the same layout —
/// `SystemRandomNumberGenerator` would reshuffle on every redraw.
struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

// MARK: - Palette extraction

enum PlaylistCoverPalette {
	/// Used when no seed song has resolvable artwork.
	static let fallback: [Color] = [
		Color(red: 0.18, green: 0.10, blue: 0.36),
		Color(red: 0.45, green: 0.18, blue: 0.52),
		Color(red: 0.10, green: 0.22, blue: 0.45),
		Color(red: 0.32, green: 0.45, blue: 0.65),
	]

	/// One dominant color per song, up to `maxColors`. Sequential
	/// thumbnail downloads, but runs once on detail-view open, off the dial
	/// hot path. `Artwork.backgroundColor` is unreliable for library items
	/// ([[project-artwork-backgroundcolor-library-gap]]), so sample pixels
	/// from a tiny thumbnail instead.
	static func extract(from songs: [Song], maxColors: Int = 4) async -> [Color] {
		var colors: [Color] = []
		for song in songs {
			if colors.count >= maxColors { break }
			guard let artwork = song.artwork,
			      let url = artwork.url(width: 64, height: 64) else { continue }
			if let color = await averageColor(at: url) {
				colors.append(color)
			}
		}
		return colors
	}

	private static func averageColor(at url: URL) async -> Color? {
		guard let (data, _) = try? await URLSession.shared.data(from: url),
		      let ciImage = CIImage(data: data) else { return nil }

		let filter = CIFilter.areaAverage()
		filter.inputImage = ciImage
		filter.extent = ciImage.extent
		guard let output = filter.outputImage else { return nil }

		var bitmap = [UInt8](repeating: 0, count: 4)
		let context = CIContext(options: [.workingColorSpace: NSNull()])
		context.render(
			output,
			toBitmap: &bitmap,
			rowBytes: 4,
			bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
			format: .RGBA8,
			colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
		)

		let r = Double(bitmap[0]) / 255.0
		let g = Double(bitmap[1]) / 255.0
		let b = Double(bitmap[2]) / 255.0
		// Area-average comes back muddy, which reads as "bug" not "minimal";
		// boost saturation, clamped so vivid palettes don't blow out.
		return boostSaturation(r: r, g: g, b: b, by: 0.25)
	}

	private static func boostSaturation(r: Double, g: Double, b: Double, by amount: Double) -> Color {
		let maxC = max(r, g, b)
		let minC = min(r, g, b)
		let delta = maxC - minC
		guard delta > 0.001 else { return Color(red: r, green: g, blue: b) }
		let mid = (maxC + minC) / 2
		let scale = 1 + amount
		let nr = clamp(mid + (r - mid) * scale)
		let ng = clamp(mid + (g - mid) * scale)
		let nb = clamp(mid + (b - mid) * scale)
		return Color(red: nr, green: ng, blue: nb)
	}

	private static func clamp(_ v: Double) -> Double {
		min(1, max(0, v))
	}
}

// MARK: - PNG rendering

enum PlaylistCoverRenderer {
	/// Render the cover to PNG data. `@MainActor` because `ImageRenderer` is.
	@MainActor
	static func renderPNG(
		title: String,
		palette: [Color]?,
		seed: UInt64,
		pixelSize: CGFloat = 1024
	) -> Data? {
		let view = PlaylistCoverArt(
			title: title,
			palette: palette,
			seed: seed,
			size: pixelSize,
			rounded: false
		)
		let renderer = ImageRenderer(content: view)
		renderer.scale = 1
		renderer.proposedSize = ProposedViewSize(width: pixelSize, height: pixelSize)
		guard let cgImage = renderer.cgImage else { return nil }
		return pngData(from: cgImage)
	}

	private static func pngData(from cgImage: CGImage) -> Data? {
		let mutable = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(
			mutable as CFMutableData,
			UTType.png.identifier as CFString,
			1,
			nil
		) else { return nil }
		CGImageDestinationAddImage(destination, cgImage, nil)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return mutable as Data
	}
}

// MARK: - Transferable wrapper

/// PNG cover art for `ShareLink`, named after the playlist title.
struct PlaylistCoverImage: Transferable {
	let title: String
	let pngData: Data

	static var transferRepresentation: some TransferRepresentation {
		DataRepresentation(exportedContentType: .png) { item in
			item.pngData
		}
		.suggestedFileName { item in "\(safeFileName(item.title)).png" }
	}

	private static func safeFileName(_ raw: String) -> String {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return "Playback cover" }
		let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>")
		return trimmed
			.components(separatedBy: banned)
			.joined(separator: " ")
	}
}

#Preview("With palette") {
	PlaylistCoverArt(
		title: "Slow burn ft. Aphex Twin",
		palette: [
			Color(red: 0.85, green: 0.35, blue: 0.20),
			Color(red: 0.30, green: 0.10, blue: 0.45),
			Color(red: 0.95, green: 0.55, blue: 0.25),
			Color(red: 0.15, green: 0.25, blue: 0.55),
		],
		seed: 0xA1B2_C3D4,
		size: 320
	)
	.padding()
}

#Preview("Fallback / no palette") {
	PlaylistCoverArt(
		title: "Afternoon drift ft. Caroline Polachek",
		palette: nil,
		seed: 0xDEAD_BEEF,
		size: 320
	)
	.padding()
}

#Preview("Short title — different seed") {
	PlaylistCoverArt(
		title: "Afterglow",
		palette: nil,
		seed: 0x5EED_5EED,
		size: 320
	)
	.padding()
}
