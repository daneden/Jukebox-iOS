//
//  PlaylistCoverArt.swift
//  Jukebox
//
//  Created by Daniel Eden on 24/05/2026.
//
//  Generated cover art for a history playlist. Minimal layout — title
//  on a mesh gradient sampled from the first few songs' album thumbnails,
//  Playback wordmark in the bottom-trailing corner. Same view drives
//  both the in-app preview and the 1024×1024 PNG produced by
//  `ImageRenderer` for sharing.
//
//  MusicKit's `createPlaylist` API doesn't accept cover art (catalogued
//  in `project-musickit-no-artwork`), so this is a manual share/save
//  flow — the user gets the file and applies it themselves.

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import ImageIO
import MusicKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - View

/// Square playlist cover. All internal sizing is proportional to `size`
/// so the same view renders identically at 280pt (preview) and 1024pt
/// (share/export).
struct PlaylistCoverArt: View {
	let title: String
	/// Up to four base colors; cycled across the 3×3 mesh after a
	/// seed-driven shuffle. Pass nil to use the neutral fallback.
	let palette: [Color]?
	/// Deterministic seed for the mesh layout — the same value always
	/// produces the same gradient, so every playlist gets its own shape
	/// while a single playlist stays visually stable across renders.
	var seed: UInt64 = 0
	var size: CGFloat = 280

	private var basePalette: [Color] {
		guard let palette, !palette.isEmpty else {
			return PlaylistCoverPalette.fallback
		}
		return (0 ..< 4).map { palette[$0 % palette.count] }
	}

	/// Effective seed — `0` is treated as "unseeded" and falls back to a
	/// fixed value so the preview canvas in Xcode doesn't reroll on
	/// every redraw.
	private var effectiveSeed: UInt64 {
		seed == 0 ? 0xC0FFEE : seed
	}

	/// 9 mesh points laid out 3×3. Corners are pinned to the rect
	/// corners; edge midpoints stay on their edge (top/bottom at Y=0/1,
	/// left/right at X=0/1) so the mesh covers the canvas edge-to-edge.
	///
	/// The free coordinates are clamped to [0.25, 0.75] rather than the
	/// full unit range. The corner positions are inviolate, so when an
	/// edge midpoint or the center wandered close to one, the adjacent
	/// quad collapsed into a near-degenerate sliver and the interpolation
	/// compressed an entire color transition into that thin band —
	/// reading as a sharp, broken-looking edge. Keeping every free point
	/// at least 25% away from the rect borders gives every quad enough
	/// width/height to interpolate smoothly while still allowing
	/// asymmetric placement (and edge midpoints crossing each other in
	/// the middle band) for distinctive per-playlist character.
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

	/// Seeded uniform sample in the safe middle band [0.25, 0.75].
	/// Narrower than the full unit range — see `meshPoints` for why
	/// approaching the corners produces visibly broken gradients.
	private func unit(_ rng: inout SeededGenerator) -> Float {
		let raw = Float(rng.next() >> 11) / Float(UInt64(1) << 53)
		return 0.25 + raw * 0.5
	}

	/// 9 colors over the 3×3 mesh. The palette is seed-shuffled and then
	/// cycled in a pattern that avoids putting the same palette entry in
	/// adjacent cells, so the blend has texture rather than reading as
	/// a single wash.
	private var meshColors: [Color] {
		var rng = SeededGenerator(seed: effectiveSeed &+ 0x9E37)
		let shuffled = basePalette.shuffled(using: &rng)
		let pattern = [0, 2, 1,
		               3, 0, 2,
		               1, 3, 0]
		return pattern.map { shuffled[$0 % shuffled.count] }
	}

	/// Combined logo glyph + "Playback" wordmark, rendered as a die-cut
	/// sticker: a white sticker base extended outward from the silhouette
	/// by `outlineWidth` on every side, the printed art (the same content
	/// in near-black) sitting on top, and a subtle dark drop shadow that
	/// makes the sticker read as raised off the cover. Both layers share
	/// one geometry via the local `wordmark` view so the outline tracks
	/// the wordmark's actual shape rather than a bounding box.
	private var diecutWordmark: some View {
		let outlineWidth: CGFloat = size * 0.006
		return ZStack {
			// White sticker base. Eight offset copies of the wordmark
			// silhouette in white form the outline by dilating the
			// shape outward — cardinals at the full outline radius,
			// diagonals at ~0.7× so the corners stay roughly circular.
			// An expression-based ForEach (rather than a chained
			// `.shadow` stack) keeps the type-checker out of trouble.
			ForEach(Self.outlineOffsets, id: \.self) { unit in
				wordmark
					.foregroundStyle(.white)
					.offset(
						x: CGFloat(unit.x) * outlineWidth,
						y: CGFloat(unit.y) * outlineWidth
					)
			}
			// Printed art on the sticker face.
			wordmark
				.foregroundStyle(Color.black.opacity(0.88))
		}
		.compositingGroup()
		.shadow(
			color: .black.opacity(0.22),
			radius: size * 0.012,
			x: 0,
			y: size * 0.005
		)
	}

	private var wordmark: some View {
		HStack(spacing: size * 0.025) {
			Image(.playback)
				.resizable()
				.renderingMode(.template)
				.aspectRatio(contentMode: .fit)
				.frame(width: size * 0.09)

			Text("Playback")
				.fontWeight(.semibold)
				.font(.system(size: size * 0.065))
		}
	}

	/// Unit offsets for the 8 directional copies that build the sticker's
	/// white outline. Cardinals at ±1, diagonals at ±0.7 (≈ 1/√2) so the
	/// corner radius of the outline stays close to circular when scaled
	/// by `outlineWidth`.
	private static let outlineOffsets: [SIMD2<Float>] = [
		[1, 0], [-1, 0], [0, 1], [0, -1],
		[0.7, 0.7], [-0.7, 0.7], [0.7, -0.7], [-0.7, -0.7],
	]

	var body: some View {
		ZStack {
			MeshGradient(
				width: 3,
				height: 3,
				points: meshPoints,
				colors: meshColors
			)

			// Subtle inner shading so the title stays readable even when
			// the sampled palette comes back light.
			LinearGradient(
				colors: [.black.opacity(0.15), .black.opacity(0)],
				startPoint: .top,
				endPoint: .bottom
			)
			.blendMode(.plusDarker)

			Text(title)
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
					diecutWordmark
				}
			}
			.padding(size * 0.065)
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.045))
		.compositingGroup()
	}
}

// MARK: - Seeded RNG

/// SplitMix64 — tiny, fast, and good enough for picking gradient
/// positions. We need *deterministic* per-playlist randomness so the
/// preview, the rendered PNG, and any later re-render all land on the
/// same layout; Swift's default `SystemRandomNumberGenerator` would
/// reshuffle on every redraw.
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
	/// Used when none of the seed songs have resolvable artwork. Tuned
	/// to feel of-a-piece with the app rather than generic.
	static let fallback: [Color] = [
		Color(red: 0.18, green: 0.10, blue: 0.36),
		Color(red: 0.45, green: 0.18, blue: 0.52),
		Color(red: 0.10, green: 0.22, blue: 0.45),
		Color(red: 0.32, green: 0.45, blue: 0.65),
	]

	/// Sample one dominant color per song for up to `maxColors` songs.
	/// Sequential downloads (4 small thumbnails total) — this runs once
	/// when the detail view opens, never on the dial hot path, so we're
	/// out of [[feedback-real-device-perf]] territory.
	///
	/// `Artwork.backgroundColor` is unreliable for library items (see
	/// [[project-artwork-backgroundcolor-library-gap]]), so we sample
	/// pixels from a tiny thumbnail instead.
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
		// Lightly boost saturation — area-average tends muted, and a
		// muddy gradient reads as "bug" instead of "minimal." Clamp so
		// already-vivid palettes don't blow out.
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
	/// Render the cover at `pixelSize` × `pixelSize` and return PNG data.
	/// Runs on `@MainActor` because `ImageRenderer` does. Returns nil if
	/// the renderer can't produce a CGImage (rare; usually a sign the
	/// view tree failed to lay out).
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
			size: pixelSize
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

/// PNG cover art ready for `ShareLink`. The `suggestedFileName` is the
/// playlist title sanitised for the filesystem so AirDrop / Save to
/// Files lands with a recognisable name rather than `image.png`.
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
