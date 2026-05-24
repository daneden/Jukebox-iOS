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
	/// Four colors used as the mesh corners (top-leading, top-trailing,
	/// bottom-leading, bottom-trailing). Pass fewer and the palette
	/// cycles; pass nil to use the neutral fallback.
	let palette: [Color]?
	var size: CGFloat = 280

	private var cornerColors: [Color] {
		guard let palette, !palette.isEmpty else {
			return PlaylistCoverPalette.fallback
		}
		return (0 ..< 4).map { palette[$0 % palette.count] }
	}

	/// Splits "phrase ft. artist" into (phrase, artist). Older history
	/// rows that fell back to `seedTitle` won't carry the marker — those
	/// render as a single headline with no subline.
	private var titleParts: (headline: String, subline: String?) {
		if let range = title.range(of: " ft. ") {
			let headline = String(title[..<range.lowerBound])
			let artist = String(title[range.upperBound...])
			return (headline, "ft. \(artist)")
		}
		return (title, nil)
	}

	var body: some View {
		ZStack {
			MeshGradient(
				width: 2,
				height: 2,
				points: [
					[0.0, 0.0], [1.0, 0.0],
					[0.0, 1.0], [1.0, 1.0],
				],
				colors: cornerColors
			)

			// Subtle inner shading so the title stays readable even when
			// the sampled palette comes back light.
			LinearGradient(
				colors: [.black.opacity(0.0), .black.opacity(0.25)],
				startPoint: .top,
				endPoint: .bottom
			)
			.blendMode(.multiply)

			VStack(alignment: .leading, spacing: size * 0.02) {
				Text(titleParts.headline)
					.font(.system(size: size * 0.14, weight: .semibold, design: .default))
					.lineLimit(4)
					.minimumScaleFactor(0.5)
					.foregroundStyle(.white)
				if let subline = titleParts.subline {
					Text(subline)
						.font(.system(size: size * 0.055, weight: .medium, design: .default))
						.foregroundStyle(.white.opacity(0.75))
						.lineLimit(2)
				}
			}
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
						.frame(width: size * 0.11)
						.foregroundStyle(.white.opacity(0.9))
				}
			}
			.padding(size * 0.065)
		}
		.frame(width: size, height: size)
		.clipShape(RoundedRectangle(cornerRadius: size * 0.045))
		.compositingGroup()
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
		pixelSize: CGFloat = 1024
	) -> Data? {
		let view = PlaylistCoverArt(title: title, palette: palette, size: pixelSize)
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
		size: 320
	)
	.padding()
}

#Preview("Fallback / no palette") {
	PlaylistCoverArt(
		title: "Afternoon drift ft. Caroline Polachek",
		palette: nil,
		size: 320
	)
	.padding()
}

#Preview("Short title") {
	PlaylistCoverArt(
		title: "Afterglow",
		palette: nil,
		size: 320
	)
	.padding()
}
