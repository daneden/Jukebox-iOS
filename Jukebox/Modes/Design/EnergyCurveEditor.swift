//
//  EnergyCurveEditor.swift
//  Jukebox
//
//  Interactive editor for the five-point energy curve. The stroked curve
//  fills with a vertical gradient running from intense (top) to glacial
//  (bottom) — matching the EnergyBand tints used elsewhere — so the
//  shape's height maps visually to its musical meaning.
//
//  The five control points are Liquid Glass capsules that drag only
//  along Y. X is fixed at evenly spaced positions so the curve stays a
//  well-formed quartic Bézier (monotonic in X) regardless of how the
//  user pulls them.
//

import SwiftUI

struct EnergyCurveEditor: View {
	@Binding var curve: EnergyCurve

	/// Inner padding so the leading/trailing control points aren't clipped
	/// when they sit flush with the editor's left/right edges. Half the
	/// thumb width plus a hair of breathing room.
	private static let horizontalInset: CGFloat = 28
	/// Vertical inset so a control point pinned at y=0 or y=1 isn't
	/// half-clipped by the editor's top/bottom edges.
	private static let verticalInset: CGFloat = 20
	private static let thumbWidth: CGFloat = 44
	private static let thumbHeight: CGFloat = 28
	private static let coordinateSpaceName = "EnergyCurveEditor"

	/// One @GestureState per control point so the press effect lifts only
	/// the thumb the user is touching. Using a single value would scale
	/// every thumb on every drag.
	@GestureState private var activePoint: Int?

	var body: some View {
		GeometryReader { geo in
			ZStack {
				bandGuides(in: geo.size)
				curvePath(in: geo.size)
				controlPoints(in: geo.size)
			}
			.frame(width: geo.size.width, height: geo.size.height)
			.coordinateSpace(name: Self.coordinateSpaceName)
		}
		.frame(minHeight: 240)
		.accessibilityElement(children: .contain)
		.accessibilityLabel("Energy curve")
	}

	// MARK: - Layout

	private func canvasRect(in size: CGSize) -> CGRect {
		CGRect(
			x: Self.horizontalInset,
			y: Self.verticalInset,
			width: max(0, size.width - 2 * Self.horizontalInset),
			height: max(0, size.height - 2 * Self.verticalInset)
		)
	}

	private func pointPosition(_ index: Int, in size: CGSize) -> CGPoint {
		let rect = canvasRect(in: size)
		let x = rect.minX + rect.width * CGFloat(index) / CGFloat(EnergyCurve.pointCount - 1)
		let y = rect.minY + rect.height * (1 - CGFloat(curve.points[index]))
		return CGPoint(x: x, y: y)
	}

	// MARK: - Band guides

	/// Faint horizontal bands behind the curve so the user can tell which
	/// quarter of the editor maps to which EnergyBand. Subtle enough that
	/// the curve remains the focal point.
	private func bandGuides(in size: CGSize) -> some View {
		let rect = canvasRect(in: size)
		return ZStack(alignment: .topLeading) {
			ForEach(Array(EnergyBand.concreteOrdered.reversed().enumerated()), id: \.element.id) { idx, band in
				Rectangle()
					.fill(band.tint.opacity(0.06))
					.frame(width: rect.width, height: rect.height / 4)
					.offset(x: rect.minX, y: rect.minY + CGFloat(idx) * rect.height / 4)
			}
		}
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
				style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
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
		// Liquid Glass capsule. `.regular.interactive()` gives the
		// material backdrop + system-driven shimmer on touch; the small
		// inner dot is a non-functional centre cue so the thumb reads
		// as a discrete handle rather than an abstract glass blob.
		return Capsule()
			.fill(.clear)
			.frame(width: Self.thumbWidth, height: Self.thumbHeight)
			.glassEffect(.regular.interactive(), in: .capsule)
			.overlay(
				Circle()
					.fill(.primary.opacity(0.5))
					.frame(width: 4, height: 4)
			)
			.shadow(color: .black.opacity(0.18), radius: 8, y: 2)
			.scaleEffect(active ? 1.35 : 1)
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
		"\(Int((y * 100).rounded()))% — \(EnergyBand.forCurveValue(y).displayName)"
	}
}

/// Sample the quartic Bézier at a dense set of t values and stroke
/// through them. Animatable over each control point so the stroke
/// interpolates smoothly when randomise runs `withAnimation`.
struct CurveShape: Shape {
	var curve: EnergyCurve
	let rect: CGRect
	var resolution: Int = 96

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
		for i in 0 ... resolution {
			let t = Double(i) / Double(resolution)
			let y = curve.sample(at: t)
			let px = rect.minX + rect.width * CGFloat(t)
			let py = rect.minY + rect.height * (1 - CGFloat(y))
			if i == 0 {
				path.move(to: CGPoint(x: px, y: py))
			} else {
				path.addLine(to: CGPoint(x: px, y: py))
			}
		}
		return path
	}
}

/// Five-component animatable bundle. SwiftUI nests AnimatablePair to
/// vectorise N values; this wrapper hides the nesting behind named
/// properties so the Shape stays readable.
struct AnimatablePointFive: VectorArithmetic {
	var p0: Double
	var p1: Double
	var p2: Double
	var p3: Double
	var p4: Double

	static var zero: AnimatablePointFive { .init(p0: 0, p1: 0, p2: 0, p3: 0, p4: 0) }

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

	static func += (lhs: inout AnimatablePointFive, rhs: AnimatablePointFive) { lhs = lhs + rhs }
	static func -= (lhs: inout AnimatablePointFive, rhs: AnimatablePointFive) { lhs = lhs - rhs }

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
					withAnimation(.smooth(duration: 0.5)) {
						curve = .random()
					}
				}
			}
		}
	}
	return Host()
}
