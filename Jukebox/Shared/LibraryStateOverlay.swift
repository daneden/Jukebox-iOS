//
//  LibraryStateOverlay.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import MusicKit
import SwiftUI

/// Overlay shown when the library is unavailable, still loading, or empty.
/// Both tabs share the same shape; the loading state uses a shared
/// cycling phrase pool (CyclingLoadingText) so the copy stays consistent
/// across surfaces. Empty/error/auth copy is still passed per-mode.
struct LibraryStateOverlay: View {
	let isEmpty: Bool
	let isLoading: Bool
	let loadError: String?
	let emptyMessage: String
	let emptyHint: String?
	let authMessage: String

	init(
		isEmpty: Bool,
		isLoading: Bool,
		loadError: String? = nil,
		emptyMessage: String,
		emptyHint: String? = nil,
		authMessage: String
	) {
		self.isEmpty = isEmpty
		self.isLoading = isLoading
		self.loadError = loadError
		self.emptyMessage = emptyMessage
		self.emptyHint = emptyHint
		self.authMessage = authMessage
	}

	var body: some View {
		switch MusicAuthorization.currentStatus {
		case .notDetermined:
			VStack {
				Spacer()
				Text("Get Started")
					.font(.headline)
				Text(authMessage)
				Button("Allow Access") {
					Task { await MusicAuthorization.request() }
				}
				.buttonStyle(.borderedProminent)
				Spacer()
			}
			.scenePadding()

		case .authorized:
			if isEmpty {
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

		default:
			EmptyView()
		}
	}
}
