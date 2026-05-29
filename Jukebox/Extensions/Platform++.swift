//
//  Platform++.swift
//  Jukebox
//
//  Shims so one View tree compiles on iOS and macOS — each no-ops on the
//  platform lacking the API, instead of `#if os(iOS)` at every call site.
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
	/// Trailing toolbar slot: `.topBarTrailing` on iOS, `.primaryAction` on macOS.
	static var trailingAction: ToolbarItemPlacement {
		#if os(iOS)
			.topBarTrailing
		#else
			.primaryAction
		#endif
	}
}
