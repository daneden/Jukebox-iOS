//
//  ToolbarLogo.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// The Playback wordmark for the toolbar's principal placement. Identical in
/// both tabs — extracted so the asset name and sizing live in one spot.
struct ToolbarLogo: View {
	var body: some View {
		Image(.playback)
			.resizable()
			.aspectRatio(contentMode: .fit)
			.frame(height: 56)
			.foregroundStyle(.primary)
	}
}
