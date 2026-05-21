//
//  OnboardingView.swift
//  Jukebox
//
//  Created by Daniel Eden on 21/05/2026.
//

import MusicKit
import SwiftUI

/// First-run sheet shown when the user hasn't yet decided on Apple Music
/// access. Presented from ContentView whenever `MusicAuthorization.currentStatus`
/// is `.notDetermined`; auto-dismisses once the user answers the system
/// prompt (status moves to `.authorized` or `.denied`).
struct OnboardingView: View {
	@Environment(\.colorScheme) private var colorScheme
	/// Invoked when the user taps Get Started. The caller is responsible for
	/// calling `MusicAuthorization.request()` and reacting to the result.
	let onGetStarted: () async -> Void

	@State private var isRequesting = false

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Spacer()

			VStack(alignment: .leading, spacing: 8) {
				Image(.playback)
					.resizable()
					.aspectRatio(contentMode: .fit)
					.frame(height: 80)
					.foregroundStyle(.primary)

				Text("Playback")
					.font(.largeTitle.leading(.tight))
					.fontWeight(.bold)

				Text("Rediscover your music.")
					.font(.largeTitle.leading(.tight))
					.foregroundStyle(.secondary)
			}

			Group {
				Text("Spin through your Apple Music library to surface the playlists and songs you'd forgotten.")
				Text("Generate new playlists based on sonic similarity.")
				Text("No accounts, no tracking, and no subscription.")
			}
			.font(.title3)
			.foregroundStyle(.secondary)

			Spacer()

			AsyncButton {
				isRequesting = true
				await onGetStarted()
				isRequesting = false
			} label: {
				Text("Get Started")
					.font(.headline)
					.frame(maxWidth: .infinity)
					.foregroundStyle(colorScheme == .dark ? .black : .white)
			}
			.buttonStyle(.glassProminent)
			.controlSize(.large)
			.disabled(isRequesting)
		}
		.scenePadding()
		.interactiveDismissDisabled()
	}
}

#Preview("Onboarding sheet") {
	// Present inside a sheet so the preview matches the production
	// presentation context (rounded corners, detents, safe areas).
	Color(.systemBackground)
		.ignoresSafeArea()
		.sheet(isPresented: .constant(true)) {
			OnboardingView {
				try? await Task.sleep(for: .seconds(1))
			}
		}
}

#Preview("Onboarding bare") {
	OnboardingView {
		try? await Task.sleep(for: .seconds(1))
	}
}
