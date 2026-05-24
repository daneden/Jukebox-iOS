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
		@State private var showingCentroidBuilder = false
	#endif

	var body: some View {
		Menu {
			Toggle("Play automatically on shuffle", systemImage: "play", isOn: $autoplay)
			Divider()
			Button {
				showingHowItWorks = true
			} label: {
				Label("How it works", systemImage: "info.circle")
			}
			#if DEBUG
				Divider()
				Button {
					showingEmbeddingSpike = true
				} label: {
					Label("Embedding spike", systemImage: "waveform.and.magnifyingglass")
				}
				Button {
					showingCentroidBuilder = true
				} label: {
					Label("Build energy centroids", systemImage: "scope")
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
			.sheet(isPresented: $showingCentroidBuilder) {
				EnergyCentroidBuilderView()
			}
		#endif
	}
}

enum SettingsKeys {
	static let autoplay = "autoplay"
	static let walkMeander = "walkControls.meander"
	static let walkEnergy = "walkControls.energy"
	static let walkDecadeLower = "walkControls.decadeLower"
	static let walkDecadeUpper = "walkControls.decadeUpper"
	static let designCurveData = "design.curveData"
	static let designSongCount = "design.songCount"
}
