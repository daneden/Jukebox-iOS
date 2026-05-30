//
//  AirPlayRouteButton.swift
//  Jukebox
//
//  System AirPlay / output-route picker, styled to match the Filters button.
//  SwiftUI ships no route-picker view and no way to present the system route
//  popover from a Button action — only AVRoutePickerView's own tap opens it.
//  So a glass Button supplies the chrome (and inherits controlSize/buttonStyle),
//  and a transparent AVRoutePickerView overlaid on top draws the glyph, captures
//  the tap, and keeps its built-in active-state tint.
//

#if os(iOS)
	import AVKit
	import SwiftUI

	struct AirPlayRouteButton: View {
		var body: some View {
			RoutePicker()
		}
	}

	private struct RoutePicker: UIViewRepresentable {
		func makeUIView(context _: Context) -> AVRoutePickerView {
			let picker = AVRoutePickerView()
			picker.backgroundColor = .clear
			picker.prioritizesVideoDevices = false
			picker.tintColor = .label
			picker.activeTintColor = .tintColor
			return picker
		}

		func updateUIView(_: AVRoutePickerView, context _: Context) {}
	}
#else
	import SwiftUI

	/// macOS plays through Music.app over AppleScript — the app owns no audio for
	/// AVRoutePickerView to route, so the control is absent here.
	struct AirPlayRouteButton: View {
		var body: some View {
			EmptyView()
		}
	}
#endif
