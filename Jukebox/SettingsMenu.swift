//
//  SettingsMenu.swift
//  Jukebox
//
//  Created by Daniel Eden on 20/05/2026.
//

import SwiftUI

/// Top-leading toolbar menu. Currently houses only the Autoplay toggle; lives
/// in its own component so both tabs render the same menu without copy-paste.
/// The setting itself is `@AppStorage`-backed, so the two tabs stay in sync.
struct SettingsMenu: View {
	@AppStorage(SettingsKeys.autoplay) private var autoplay: Bool = true

	var body: some View {
		Menu {
			Toggle("Autoplay on Shuffle", isOn: $autoplay)
		} label: {
			Label("Settings", systemImage: "gearshape")
		}
	}
}

enum SettingsKeys {
	static let autoplay = "autoplay"
}
