//
//  PrimaryToolbar.swift
//  Jukebox
//
//  Created by Daniel Eden on 29/05/2026.
//
//  Shared top toolbar for the main tabs, so chrome doesn't shift when switching.
//

import SwiftUI

private struct PrimaryToolbar: ViewModifier {
	@State private var showingHistory = false

	func body(content: Content) -> some View {
		content
			.toolbar {
				ToolbarItem(placement: .navigation) { SettingsMenu() }
				#if os(iOS)
					// macOS renders the wordmark inline; the principal slot competes with window chrome.
					ToolbarItem(placement: .principal) { ToolbarLogo() }
				#endif
				ToolbarItem(placement: .trailingAction) {
					EmbeddingProgressIndicator(progress: .shared)
				}
				ToolbarItem(placement: .trailingAction) {
					Button {
						showingHistory = true
					} label: {
						Label("History", systemImage: "clock.arrow.circlepath")
					}
				}
			}
			.sheet(isPresented: $showingHistory) {
				HistoryView()
			}
	}
}

extension View {
	/// Apply the shared top toolbar used by every main tab.
	func primaryToolbar() -> some View {
		modifier(PrimaryToolbar())
	}
}
