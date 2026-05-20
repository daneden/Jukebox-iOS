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
	@State private var showingProbe = false
	@State private var showingEmbeddingSpike = false
	@State private var showingHowItWorks = false

	var body: some View {
		Menu {
			Toggle("Autoplay on Shuffle", isOn: $autoplay)
			Divider()
			Button {
				showingHowItWorks = true
			} label: {
				Label("How It Works", systemImage: "info.circle")
			}
			Divider()
			Button {
				showingProbe = true
			} label: {
				Label("Audio Metadata Probe", systemImage: "waveform.path.ecg")
			}
			Button {
				showingEmbeddingSpike = true
			} label: {
				Label("Embedding Spike", systemImage: "waveform.and.magnifyingglass")
			}
		} label: {
			Label("Settings", systemImage: "gearshape")
		}
		.sheet(isPresented: $showingProbe) {
			AudioMetadataProbeView()
		}
		.sheet(isPresented: $showingEmbeddingSpike) {
			EmbeddingSpikeView()
		}
		.sheet(isPresented: $showingHowItWorks) {
			HowItWorksView()
		}
	}
}

enum SettingsKeys {
	static let autoplay = "autoplay"
}
