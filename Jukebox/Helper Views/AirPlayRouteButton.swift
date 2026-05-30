//
//  AirPlayRouteButton.swift
//  Jukebox
//
//  System AirPlay / output-route picker, styled to sit beside Play + Shuffle.
//  SwiftUI ships no route-picker view, so this wraps AVKit's AVRoutePickerView.
//

#if os(iOS)
	import AVKit
	import SwiftUI

	struct AirPlayRouteButton: View {
		var body: some View {
			RoutePicker()
				.frame(width: 44, height: 44)
				.glassEffect(.regular.interactive(), in: .circle)
				.accessibilityLabel("AirPlay")
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
