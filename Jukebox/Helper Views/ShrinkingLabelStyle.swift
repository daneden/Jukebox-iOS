//
//  ShrinkingLabelStyle.swift
//  Jukebox
//
//  Created by Daniel Eden on 03/07/2023.
//

import SwiftUI

struct ShrinkingLabelStyle: LabelStyle {
	var compact = false
	func makeBody(configuration: Configuration) -> some View {
		Label {
			if !compact {
				configuration.title
					.lineLimit(1)
					.transition(.scale.combined(with: .opacity).combined(with: .move(edge: .trailing)))
			}
		} icon: {
			configuration.icon
		}
	}
}

fileprivate struct ShrinkingLabelStylePreview: View {
	@State var leadingContentVisible = false
	var body: some View {
		HStack {
			if leadingContentVisible {
				Text("This content should cause the button to shrink")
					.transition(.move(edge: .leading).combined(with: .scale))
					
			}
			
			Button {
				withAnimation {
					leadingContentVisible.toggle()
				}
			} label: {
				Label("Toggle content", systemImage: "eye")
					.labelStyle(ShrinkingLabelStyle(compact: leadingContentVisible))
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.extraLarge)
		}
		.scenePadding()
	}
}

#Preview {
    ShrinkingLabelStylePreview()
}
