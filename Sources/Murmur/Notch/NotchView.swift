import SwiftUI

/// What the corner notch is currently showing, derived from the controller.
enum NotchMode: Equatable {
    case hidden, recording, transcribing, result, message
}

@MainActor
enum NotchLayout {
    static let flare: CGFloat = 10

    static func mode(_ c: AppController) -> NotchMode {
        switch c.phase {
        case .loading, .idle: return .hidden
        case .recording: return c.showRecording ? .recording : .hidden
        case .transcribing: return .transcribing
        case .result: return .result
        case .message: return .message
        }
    }

    /// Full shape size including the flares. Hidden collapses all the way into the corner.
    static func size(_ c: AppController) -> CGSize {
        let body: CGSize
        switch mode(c) {
        case .hidden: return .zero
        case .recording, .transcribing:
            body = CGSize(width: 196, height: 50)
        case .message:
            let chars = { if case .message(let t) = c.phase { return t.count } else { return 20 } }()
            body = CGSize(width: min(380, max(150, CGFloat(chars) * 8 + 60)), height: 50)
        case .result:
            if case .result(let text, _) = c.phase {
                let wrapped = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 54.0))) }
                let lines = max(1, min(8, wrapped))
                body = CGSize(width: 440, height: CGFloat(lines) * 19 + 100)
            } else {
                body = CGSize(width: 440, height: 120)
            }
        }
        return CGSize(width: body.width + flare, height: body.height + flare)
    }
}

struct NotchView: View {
    let controller: AppController

    private var mode: NotchMode { NotchLayout.mode(controller) }
    private var size: CGSize { NotchLayout.size(controller) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            ZStack(alignment: .topLeading) {
                CornerNotchShape(flare: NotchLayout.flare, radius: 22)
                    .fill(Color.black)
                if mode != .hidden {
                    content
                        .padding(.leading, NotchLayout.flare + 16)
                        .padding(.top, NotchLayout.flare + 12)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(CornerNotchShape(flare: NotchLayout.flare, radius: 22))
            .contentShape(Rectangle())
            .onTapGesture {
                if mode == .recording { controller.stopRecording() }
            }
        }
        .animation(animation, value: size)
        .animation(animation, value: mode)
        .preferredColorScheme(.dark)
    }

    /// Bouncy when growing; no overshoot when tucking into the corner, so the size never dips below zero.
    private var animation: Animation {
        mode == .hidden ? .smooth(duration: 0.32) : .spring(response: 0.38, dampingFraction: 0.82)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.frame(height: 26)
            detail
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header row

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            switch mode {
            case .recording, .transcribing:
                Spacer(minLength: 0)
                DriftWave(
                    levels: controller.levels,
                    locked: controller.locked,
                    processing: mode == .transcribing)
                ElapsedTime(start: controller.recordingStartedAt, end: controller.recordingEndedAt)
                Spacer(minLength: 0)
            case .message:
                Spacer(minLength: 0)
                if case .message(let text) = controller.phase { Label(text) }
                Spacer(minLength: 0)
            case .result:
                Image(systemName: "text.quote").foregroundStyle(.white.opacity(0.85))
                    .font(.system(size: 13, weight: .semibold))
                if case .result(_, let pasted) = controller.phase {
                    Label(pasted ? "Pasted — copy if it didn't land" : "No text field focused", dim: true)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark") { controller.collapse() }
            case .hidden:
                EmptyView()
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch mode {
        case .result:
            if case .result(let text, _) = controller.phase {
                VStack(alignment: .trailing, spacing: 10) {
                    ScrollView {
                        Text(text).font(.system(size: 13.5)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .scrollIndicators(.never)
                    CopyButton(copied: controller.copied, compact: false) { controller.copy(text) }
                }
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Pieces

private struct Label: View {
    let text: String
    var dim = false

    init(_ text: String, dim: Bool = false) {
        self.text = text
        self.dim = dim
    }

    var body: some View {
        Text(text).font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(dim ? 0.55 : 0.9))
            .lineLimit(1)
    }
}

/// m:ss since dictation started; digits roll smoothly as they change, and freeze once you stop.
private struct ElapsedTime: View {
    let start: Date
    let end: Date?

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { timeline in
            let seconds = max(0, Int((end ?? timeline.date).timeIntervalSince(start) + 0.01))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 13.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(end == nil ? 0.9 : 0.45))
                .fixedSize()
                .contentTransition(.numericText(value: Double(seconds)))
                .animation(.smooth(duration: 0.4), value: seconds)
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

private struct CopyButton: View {
    let copied: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                if !compact || copied {
                    Text(copied ? "Copied" : "Copy").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(compact ? .white : .black)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: compact ? 24 : 28)
            .background(Capsule().fill(compact ? Color.white.opacity(0.14) : Color.white))
        }
        .buttonStyle(.plain)
    }
}
