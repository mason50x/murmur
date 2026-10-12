import SwiftUI

/// A notch growing out of the screen's bottom-right corner: flush with the bottom and right
/// edges, a rounded outer (top-left) corner, and concave flares where it meets each edge.
/// The flares take `flare` points on the top and left, so the body is `size - flare` each way;
/// they shrink with tiny rects so the shape collapses cleanly into the corner.
struct CornerNotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set {
            flare = newValue.first
            radius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(flare, min(rect.width, rect.height) / 4)
        let r = min(radius, (rect.width - f) / 2, (rect.height - f) / 2)
        let top = rect.minY + f
        let left = rect.minX + f
        var p = Path()
        // Flare into the right screen edge.
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: top), control: CGPoint(x: rect.maxX, y: top))
        // Top edge → rounded outer corner → left edge.
        p.addLine(to: CGPoint(x: left + r, y: top))
        p.addQuadCurve(to: CGPoint(x: left, y: top + r), control: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - f))
        // Flare into the bottom screen edge.
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
