//
//  Platform++.swift
//  Jukebox
//
//  Small shims that let the same View tree compile on iOS and macOS.
//  Each helper no-ops on the platform that lacks the underlying API
//  rather than splitting call sites with `#if os(iOS)` everywhere.
//

import SwiftUI

extension View {
	/// `.navigationBarTitleDisplayMode(.inline)` on iOS; identity on macOS,
	/// which has no large/inline title mode for `NavigationStack`.
	@ViewBuilder
	func inlineNavigationTitle() -> some View {
		#if os(iOS)
			navigationBarTitleDisplayMode(.inline)
		#else
			self
		#endif
	}
}

extension ToolbarItemPlacement {
	/// Trailing position in a navigation/window toolbar. Maps to
	/// `.topBarTrailing` on iOS (which only exists there) and `.primaryAction`
	/// on macOS, which lands buttons in the equivalent leading-of-window
	/// trailing slot on a `NavigationStack` toolbar.
	static var trailingAction: ToolbarItemPlacement {
		#if os(iOS)
			.topBarTrailing
		#else
			.primaryAction
		#endif
	}
}
