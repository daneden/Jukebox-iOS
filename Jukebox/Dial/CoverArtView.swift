//
//  CoverArtView.swift
//  Jukebox
//
//  Created by Daniel Eden on 25/06/2025.
//

import MusicKit
import SwiftUI

/// Generic cover-art tile. Renders an `Artwork` if present, or a placeholder
/// symbol on a material background. Used by both the playlist and song dials.
struct CoverArtView: View {
	@Environment(\.displayScale) private var displayScale
	let artwork: Artwork?
	var width: Double = 180
	/// Points to request artwork at. Smaller than `width` shrinks the pixel buffer
	/// and upscales the view — the dial uses this; upscale is invisible off-focus.
	var requestedWidth: Double? = nil
	var placeholderSymbol: String = "music.note.list"

	private let clipShape = RoundedRectangle(cornerRadius: 12)

	var body: some View {
		Group {
			if let artwork {
				let request = requestedWidth ?? width
				ZStack {
					// Backdrop in the album's color so an unloaded cover reads as
					// "this album". Library artwork has no backgroundColor
					// (catalog-only), so it falls through to material.
					if let cgColor = artwork.backgroundColor {
						Color(cgColor: cgColor)
					} else {
						Rectangle().fill(.regularMaterial)
					}

					// ArtworkImage, not AsyncImage(artwork.url) — library covers go
					// through MusicKit's cached pipeline. Per-tile AsyncImage spun up
					// uncached loads; the 7-tile burst on deck-landing raced musicd's
					// cold-launch init and wedged it (blank covers, stalled requests).
					ArtworkImage(artwork, width: request, height: request)
						.scaleEffect(width / request, anchor: .center)
				}
				.frame(width: width, height: width)
				.clipShape(clipShape)
				.overlay {
					clipShape
						.fill(.clear)
						.strokeBorder(Color.white.opacity(0.2), lineWidth: 1.0 / displayScale)
						.blendMode(.plusLighter)
				}
			} else {
				clipShape
					.fill(.regularMaterial)
					.frame(width: width, height: width)
					.overlay {
						Image(systemName: placeholderSymbol)
							.resizable()
							.aspectRatio(contentMode: .fit)
							.frame(width: width / 2)
							.foregroundStyle(.tertiary)
					}
			}
		}
		#if os(iOS)
		.contentShape(.contextMenuPreview, clipShape)
		#endif
		.contentShape(.dragPreview, clipShape)
	}
}
