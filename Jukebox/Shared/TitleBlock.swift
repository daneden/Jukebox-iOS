//
//  TitleBlock.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//

import SwiftUI

/// The two-line title shown beneath the dial. Reserves space so the dial
/// doesn't shift up when the title empties out mid-spin.
struct TitleBlock: View {
	let title: String
	let subtitle: String
	var onTap: () -> Void = {}

	var body: some View {
		VStack(spacing: 4) {
			Text(title)
				.font(.title2)
				.fontWeight(.semibold)
				.multilineTextAlignment(.center)
				.lineLimit(2)

			Text(subtitle)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.lineLimit(1, reservesSpace: true)
		}
		.contentTransition(.numericText())
		.padding(.horizontal, 24)
		.padding(.bottom, 24)
		.contentShape(.rect)
		.onTapGesture { onTap() }
	}
}
