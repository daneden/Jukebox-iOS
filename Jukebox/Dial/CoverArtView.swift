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
		if let artwork {
			let request = requestedWidth ?? width
			ArtworkImage(artwork, width: request, height: request)
				.scaleEffect(width / request, anchor: .center)
				.frame(width: width, height: width)
				.clipShape(clipShape)
				.overlay {
					clipShape
						.fill(.clear)
						.strokeBorder(Color.white.opacity(0.2), lineWidth: 1.0 / displayScale)
						.blendMode(.plusLighter)
				}
				.drawingGroup()
				.background(.regularMaterial, in: clipShape)
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
}
