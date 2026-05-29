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
	/// Points to request the artwork at. When smaller than `width`, the resulting
	/// pixel buffer is smaller and the view is scaled up — useful for memory-tight
	/// uses like the dial, where a slight upscale is invisible at non-focused sizes.
	var requestedWidth: Double? = nil
	var placeholderSymbol: String = "music.note.list"

	private let clipShape = RoundedRectangle(cornerRadius: 12)

	var body: some View {
		Group {
			if let artwork {
				let request = requestedWidth ?? width
				ZStack {
					// Backdrop fill matching the album's predominant color, so a
					// not-yet-loaded cover reads as "this album" rather than a
					// blank tile. Library artwork carries no backgroundColor
					// (catalog-only metadata), so it falls through to material.
					if let cgColor = artwork.backgroundColor {
						Color(cgColor: cgColor)
					} else {
						Rectangle().fill(.regularMaterial)
					}
					
					// ArtworkImage — MusicKit's own loader — rather than
					// AsyncImage(artwork.url(…)). Library covers resolve through a
					// musickit:// URL served by itunescloudd / mediaartworkd;
					// ArtworkImage fetches them via MusicKit's coordinated, cached
					// pipeline. Driving one AsyncImage per tile instead spun up
					// independent, uncached URLSession loads against those daemons,
					// and the 7-tile burst the moment a deck landed raced musicd's
					// cold-launch init and wedged it — blank covers, library
					// requests that never returned, and SwiftData reads stalling
					// behind the back-pressure, until the daemon recovered.
					// `requestedWidth` keeps the decoded buffer small; scaleEffect
					// upsamples non-focused tiles to display size.
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
