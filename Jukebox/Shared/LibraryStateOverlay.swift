//
//  LibraryStateOverlay.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Overlay shown when the authorized library is still loading or empty.
/// Both tabs share the same shape; the loading state uses a shared
/// cycling phrase pool (CyclingLoadingText) so the copy stays consistent
/// across surfaces. Empty/error copy is still passed per-mode.
///
/// First-run authorization is handled by `OnboardingView`, presented as a
/// sheet from `ContentView` — this overlay only renders for `.authorized`.
struct LibraryStateOverlay: View {
	let isEmpty: Bool
	let isLoading: Bool
	let loadError: String?
	let emptyMessage: String
	let emptyHint: String?

	init(
		isEmpty: Bool,
		isLoading: Bool,
		loadError: String? = nil,
		emptyMessage: String,
		emptyHint: String? = nil
	) {
		self.isEmpty = isEmpty
		self.isLoading = isLoading
		self.loadError = loadError
		self.emptyMessage = emptyMessage
		self.emptyHint = emptyHint
	}

	var body: some View {
		if MusicAuthorization.currentStatus == .authorized, isEmpty {
			VStack(spacing: 12) {
				Spacer()
				if isLoading {
					ProgressView()
						.controlSize(.large)
					CyclingLoadingText()
						.font(.subheadline)
						.foregroundStyle(.secondary)
				} else if let loadError {
					Text(loadError)
						.foregroundStyle(.secondary)
				} else {
					Text(emptyMessage)
						.foregroundStyle(.secondary)
					if let emptyHint {
						Text(emptyHint)
							.font(.footnote)
							.foregroundStyle(.tertiary)
							.multilineTextAlignment(.center)
					}
				}
				Spacer()
			}
			.transition(.opacity)
			.scenePadding()
		}
	}
}
