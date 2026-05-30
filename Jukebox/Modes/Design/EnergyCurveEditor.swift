//
//  EnergyCurveEditor.swift
//  Jukebox
//
//  Interactive editor for the five-point energy curve. Five 44pt Liquid
//  Glass control points drag only along Y (X is fixed at evenly spaced
//  positions), with a vertical gradient from intense (top) to glacial
//  (bottom) so the shape's height maps to its musical meaning.
//

import SwiftUI

struct EnergyCurveEditor: View {
	@Binding var curve: EnergyCurve
	/// Drives the backdrop's dot count — one dot per song slot, a visual
	/// echo of the length slider.
	var songCount: Int = 20

	/// Inset of the thumb-centre track from the editor frame, so the 44pt
	/// thumbs sit visually inside the grid rather than off the edges.
	private static let thumbInset: CGFloat = 32
	/// 44pt — Apple's minimum touch target. Smaller was reported as fiddly.
	private static let thumbSize: CGFloat = 44
	private static let coordinateSpaceName = "EnergyCurveEditor"

	/// One @GestureState per point so the press effect lifts only the
	/// touched thumb, not all of them.
	@GestureState private var activePoint: Int?

	var body: some View {
		GeometryReader { geo in
			ZStack {
				backdrop
				axisLabel("INTENSE")
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				axisLabel("GLACIAL")
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
				curvePath(in: geo.size)
				controlPoints(in: geo.size)
			}
			.frame(width: geo.size.width, height: geo.size.height)
			.coordinateSpace(name: Self.coordinateSpaceName)
		}
		.aspectRatio(1, contentMode: .fit)
		.frame(minHeight: 240)
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Energy curve")
	}

	// MARK: - Layout

	/// Region the thumb centres can travel.
	private func canvasRect(in size: CGSize) -> CGRect {
		CGRect(
			x: Self.thumbInset,
			y: Self.thumbInset,
			width: max(0, size.width - 2 * Self.thumbInset),
			height: max(0, size.height - 2 * Self.thumbInset)
		)
	}

	private func pointPosition(_ index: Int, in size: CGSize) -> CGPoint {
		let rect = canvasRect(in: size)
		let x = rect.minX + rect.width * CGFloat(index) / CGFloat(EnergyCurve.pointCount - 1)
		let y = rect.minY + rect.height * (1 - CGFloat(curve.points[index]))
		return CGPoint(x: x, y: y)
	}

	// MARK: - Backdrop

	/// Rounded-rect container with a songCount×songCount dot grid, drawn
	/// in a single `Canvas` so even a 50×50 grid stays cheap.
	private var backdrop: some View {
		let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
		let count = max(1, songCount)
		return shape
			.fill(.quinary)
			.overlay {
				Canvas { context, canvasSize in
					let inset: CGFloat = 16
					let usableW = max(0, canvasSize.width - 2 * inset)
					let usableH = max(0, canvasSize.height - 2 * inset)
					guard usableW > 0, usableH > 0 else { return }
					let cellW = usableW / CGFloat(count)
					let cellH = usableH / CGFloat(count)
					let dotSize: CGFloat = 1.5
					let half = dotSize / 2
					let colour = GraphicsContext.Shading.color(.primary.opacity(0.25))
					for r in 0 ..< count {
						let cy = inset + cellH * (CGFloat(r) + 0.5)
						for c in 0 ..< count {
							let cx = inset + cellW * (CGFloat(c) + 0.5)
							let dot = Path(ellipseIn: CGRect(
								x: cx - half, y: cy - half,
								width: dotSize, height: dotSize
							))
							context.fill(dot, with: colour)
						}
					}
				}
				.clipShape(shape)
			}
			.allowsHitTesting(false)
	}

	// MARK: - Axis labels

	private func axisLabel(_ text: String) -> some View {
		Text(text)
			.font(.caption2.weight(.semibold))
			.tracking(1)
			.foregroundStyle(.secondary)
			.padding(4)
			.padding(.horizontal, 4)
			.background(.quinary)
			.background(.background)
			.drawingGroup(opaque: true)
			.clipShape(.capsule)
			.padding(12)
			.allowsHitTesting(false)
	}

	// MARK: - Curve

	private func curvePath(in size: CGSize) -> some View {
		let rect = canvasRect(in: size)
		return CurveShape(curve: curve, rect: rect)
			.stroke(
				LinearGradient(
					colors: [
						EnergyBand.intense.tint,
						EnergyBand.energetic.tint,
						EnergyBand.mellow.tint,
						EnergyBand.glacial.tint,
					],
					startPoint: .top,
					endPoint: .bottom
				),
				style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
			)
			.shadow(color: .black.opacity(0.1), radius: 6, y: 2)
			.allowsHitTesting(false)
	}

	// MARK: - Control points

	private func controlPoints(in size: CGSize) -> some View {
		GlassEffectContainer(spacing: 0) {
			ZStack(alignment: .topLeading) {
				ForEach(0 ..< EnergyCurve.pointCount, id: \.self) { i in
					controlPoint(at: i, in: size)
				}
			}
		}
	}

	private func controlPoint(at index: Int, in size: CGSize) -> some View {
		let pos = pointPosition(index, in: size)
		let active = activePoint == index
		// `.fill(.clear)` paints nothing, so on macOS only the inner dot is
		// hit-testable — gestures on the glass rim miss the thumb.
		// `.contentShape(Circle())` declares the full 44pt gesture target.
		return Circle()
			.fill(.clear)
			.frame(width: Self.thumbSize, height: Self.thumbSize)
			.contentShape(Circle())
			.glassEffect(.regular.interactive(), in: .circle)
			.overlay(
				Circle()
					.fill(.primary.opacity(0.5))
					.frame(width: 6, height: 6)
			)
			.shadow(color: .black.opacity(0.18), radius: 8, y: 2)
			.scaleEffect(active ? 1.2 : 1)
			.animation(active
				? .interactiveSpring(duration: 0.18, extraBounce: 0.2)
				: .smooth(duration: 0.22), value: active)
			.position(pos)
			.gesture(
				DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
					.updating($activePoint) { _, state, _ in state = index }
					.onChanged { value in
						let rect = canvasRect(in: size)
						guard rect.height > 0 else { return }
						let rawY = value.location.y - rect.minY
						let fraction = 1 - Double(rawY / rect.height)
						curve.points[index] = min(1, max(0, fraction))
					}
			)
			.accessibilityElement()
			.accessibilityLabel("Point \(index + 1)")
			.accessibilityValue(Self.accessibilityValue(for: curve.points[index]))
			.accessibilityAdjustableAction { direction in
				let delta: Double = direction == .increment ? 0.1 : -0.1
				curve.points[index] = min(1, max(0, curve.points[index] + delta))
			}
	}

	private static func accessibilityValue(for y: Double) -> String {
		"\(Int((y * 100).rounded()))% — \(EnergyBand.forValue(y).displayName)"
	}
}

/// Strokes the Catmull-Rom spline as cubic-Bézier segments using the same
/// conversion as `EnergyCurve.sample`, so the stroke matches the values
/// fed to the builder. Animatable over the five Y values so randomise
/// tweens through intermediate shapes.
struct CurveShape: Shape {
	var curve: EnergyCurve
	let rect: CGRect

	var animatableData: AnimatablePointFive {
		get {
			AnimatablePointFive(
				p0: curve.points[0],
				p1: curve.points[1],
				p2: curve.points[2],
				p3: curve.points[3],
				p4: curve.points[4]
			)
		}
		set {
			curve.points = [newValue.p0, newValue.p1, newValue.p2, newValue.p3, newValue.p4]
		}
	}

	func path(in _: CGRect) -> Path {
		var path = Path()
		guard rect.width > 0, rect.height > 0 else { return path }
		let n = curve.points.count
		guard n >= 2 else { return path }
		let segments = n - 1
		let segmentWidth = rect.width / CGFloat(segments)

		func screenPoint(index: Int) -> CGPoint {
			let cx = rect.minX + segmentWidth * CGFloat(index)
			let cy = rect.minY + rect.height * (1 - CGFloat(curve.points[index]))
			return CGPoint(x: cx, y: cy)
		}

		path.move(to: screenPoint(index: 0))
		for seg in 0 ..< segments {
			let p1 = curve.points[seg]
			let p2 = curve.points[seg + 1]
			// Reflect missing neighbours so endpoint segments get a sensible tangent.
			let pPrev = seg == 0 ? (2 * p1 - p2) : curve.points[seg - 1]
			let pNext = seg == segments - 1 ? (2 * p2 - p1) : curve.points[seg + 2]

			let b1y = p1 + (p2 - pPrev) / 6
			let b2y = p2 - (pNext - p1) / 6
			// X handles at 1/3 and 2/3 across the segment (uniform X spacing).
			let b1x = rect.minX + segmentWidth * (CGFloat(seg) + 1.0 / 3.0)
			let b2x = rect.minX + segmentWidth * (CGFloat(seg) + 2.0 / 3.0)
			let b1ScreenY = rect.minY + rect.height * (1 - CGFloat(b1y))
			let b2ScreenY = rect.minY + rect.height * (1 - CGFloat(b2y))

			path.addCurve(
				to: screenPoint(index: seg + 1),
				control1: CGPoint(x: b1x, y: b1ScreenY),
				control2: CGPoint(x: b2x, y: b2ScreenY)
			)
		}
		return path
	}
}

/// Five-component animatable bundle — named properties over nested
/// AnimatablePairs so the Shape stays readable.
struct AnimatablePointFive: VectorArithmetic {
	var p0: Double
	var p1: Double
	var p2: Double
	var p3: Double
	var p4: Double

	static var zero: AnimatablePointFive {
		.init(p0: 0, p1: 0, p2: 0, p3: 0, p4: 0)
	}

	static func + (lhs: AnimatablePointFive, rhs: AnimatablePointFive) -> AnimatablePointFive {
		AnimatablePointFive(
			p0: lhs.p0 + rhs.p0, p1: lhs.p1 + rhs.p1,
			p2: lhs.p2 + rhs.p2, p3: lhs.p3 + rhs.p3, p4: lhs.p4 + rhs.p4
		)
	}

	static func - (lhs: AnimatablePointFive, rhs: AnimatablePointFive) -> AnimatablePointFive {
		AnimatablePointFive(
			p0: lhs.p0 - rhs.p0, p1: lhs.p1 - rhs.p1,
			p2: lhs.p2 - rhs.p2, p3: lhs.p3 - rhs.p3, p4: lhs.p4 - rhs.p4
		)
	}

	static func += (lhs: inout AnimatablePointFive, rhs: AnimatablePointFive) {
		lhs = lhs + rhs
	}

	static func -= (lhs: inout AnimatablePointFive, rhs: AnimatablePointFive) {
		lhs = lhs - rhs
	}

	mutating func scale(by rhs: Double) {
		p0 *= rhs; p1 *= rhs; p2 *= rhs; p3 *= rhs; p4 *= rhs
	}

	var magnitudeSquared: Double {
		p0 * p0 + p1 * p1 + p2 * p2 + p3 * p3 + p4 * p4
	}
}

#Preview {
	struct Host: View {
		@State private var curve = EnergyCurve.default
		var body: some View {
			VStack {
				EnergyCurveEditor(curve: $curve)
					.padding()
				Button("Randomise") {
					withAnimation(.snappy) {
						curve = .random()
					}
				}
			}
		}
	}
	return Host()
}
