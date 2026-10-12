import SwiftUI

/// The recording waveform: pixels are emitted from a live nucleus at the center and drift outward
/// to both sides. Each particle's vertical spread is set by how loud you were when it was born,
/// and it tapers and fades as it travels, so loud speech blooms into a cloud that dissolves at the
/// edges while silence settles into a thin flowing line. Monochrome with a soft additive glow.
struct DriftWave: View {
    let levels: [Float]
    let locked: Bool
    let processing: Bool

    static let size = CGSize(width: 96, height: 30)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            Canvas { ctx, size in
                Self.render(in: &ctx, size: size, levels: levels, t: t, locked: locked, processing: processing)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Rendering

    private static let count = 120
    private static let life = 1.25  // seconds for a particle to reach the edge
    private static let step = 0.04  // seconds between level samples

    static func render(
        in ctx: inout GraphicsContext, size: CGSize, levels: [Float], t: Double, locked: Bool, processing: Bool
    ) {
        let gain = processing ? 0.35 : 1.0
        ctx.blendMode = .plusLighter
        ctx.drawLayer { glow in
            glow.addFilter(.blur(radius: 2.2))
            particles(&glow, size, levels, t, gain: gain * 0.55, bloom: true)
        }
        ctx.blendMode = .normal
        particles(&ctx, size, levels, t, gain: gain, bloom: false)

        if processing {
            // A scan band sweeping across while the final transcript is computed.
            let x = (t * 1.6).truncatingRemainder(dividingBy: 1) * (size.width + 24) - 12
            ctx.drawLayer { band in
                band.clip(to: Path(CGRect(x: x - 7, y: 0, width: 14, height: size.height)))
                particles(&band, size, levels, t, gain: 1, bloom: false)
            }
        }
        if locked {
            ctx.fill(
                Path(CGRect(x: 6, y: size.height / 2 - 0.5, width: size.width - 12, height: 1)),
                with: .color(.white.opacity(0.18)))
        }
    }

    private static func particles(
        _ ctx: inout GraphicsContext, _ size: CGSize, _ levels: [Float], _ t: Double, gain: Double, bloom: Bool
    ) {
        let cx = size.width / 2
        let cy = size.height / 2
        let hw = size.width / 2 - 3
        let hh = size.height / 2 - 2.5

        func level(_ k: Int) -> Double {
            let i = levels.count - 1 - k
            return i >= 0 && i < levels.count ? Double(levels[i]) : 0
        }

        func pixel(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ a: Double) {
            let a = min(max(a * gain, 0), 1)
            guard a > 0.02 else { return }
            let s = bloom ? s * 1.7 : s
            ctx.fill(Path(CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)), with: .color(.white.opacity(a)))
        }

        for i in 0..<count {
            let seed = hash(i, 1)
            let speed = 0.85 + 0.3 * hash(i, 4)
            let age = (t / life * speed + seed).truncatingRemainder(dividingBy: 1)
            let dir: Double = i.isMultiple(of: 2) ? 1 : -1
            // Loudness when this particle left the nucleus.
            let lv = level(Int(age * life / speed / step))
            let travel = pow(age, 0.8)  // eases out from the center
            // Triangular lane distribution: denser near the center line.
            let lane = hash(i, 2) + hash(i, 5) - 1
            let spread = (0.06 + 0.94 * lv) * hh * (1 - 0.4 * age)
            let wobble = sin(age * 6 + seed * 20) * 0.8 * lv
            let x = (cx + dir * travel * hw).rounded()
            let y = (cy + lane * spread + wobble).rounded()
            let fadeIn = min(age / 0.06, 1)
            let alpha = pow(1 - age, 1.1) * (0.42 + 0.58 * lv) * fadeIn
            let s = (1.3 + 1.1 * hash(i, 3)) * (0.85 + 0.4 * lv)
            pixel(x, y, s, alpha)
        }

        // Nucleus: a few pixels jittering at the source, as loud as you are right now.
        let now = level(0) * 0.6 + level(1) * 0.3 + level(2) * 0.1
        let tick = Int(t * 20)
        for j in 0..<6 {
            let r = 1 + now * 3.5
            let x = (cx + (hash(j, tick) * 2 - 1) * r).rounded()
            let y = (cy + (hash(j, tick, 7) * 2 - 1) * r * 0.7).rounded()
            pixel(x, y, 1.6, 0.45 + 0.55 * now)
        }
    }

    private static func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
        var x = UInt64(truncatingIfNeeded: a &* 73_856_093)
        x ^= UInt64(truncatingIfNeeded: b &* 19_349_663)
        x ^= UInt64(truncatingIfNeeded: c &* 83_492_791)
        x = (x ^ (x >> 33)) &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }
}
