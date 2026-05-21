//
//  SettingsMenu.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// Top-leading toolbar menu. Lives in its own component so both tabs render
/// the same menu without copy-paste; all settings are `@AppStorage`-backed
/// so the two tabs stay in sync.
struct SettingsMenu: View {
	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true
	@State private var showingHowItWorks = false
	#if DEBUG
		@State private var showingEmbeddingSpike = false
	#endif

	var body: some View {
		Menu {
			Toggle("Autoplay on Shuffle", isOn: $autoplay)
			Divider()
			Button {
				showingHowItWorks = true
			} label: {
				Label("How It Works", systemImage: "info.circle")
			}
			#if DEBUG
				Divider()
				Button {
					showingEmbeddingSpike = true
				} label: {
					Label("Embedding Spike", systemImage: "waveform.and.magnifyingglass")
				}
			#endif
		} label: {
			Label("Settings", systemImage: "gearshape")
		}
		.sheet(isPresented: $showingHowItWorks) {
			HowItWorksView()
		}
		#if DEBUG
		.sheet(isPresented: $showingEmbeddingSpike) {
				EmbeddingSpikeView()
			}
		#endif
	}
}

enum SettingsKeys {
	static let autoplay = "autoplay"
	static let walkMeander = "walkControls.meander"
	static let walkEnergy = "walkControls.energy"
	static let walkDecadeSpan = "walkControls.decadeSpan"
}
