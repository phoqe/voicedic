import AppKit
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    enum Mode: Equatable {
        case recording(handsFree: Bool)
        case working(String)
        case message(String, isError: Bool)
    }

    static let barCount = 12

    var mode: Mode = .recording(handsFree: false)
    var levels: [Float] = Array(repeating: 0, count: barCount)
    /// False while the island is tucked into the notch (or, on screens without one, hidden).
    var isPresented = false
    /// The camera notch on the island's screen; nil on screens without one.
    var notch: CGSize?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// A Dynamic Island-style overlay that grows out of the MacBook notch. On screens without a notch it
/// hangs from the top center of the screen instead.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?

    /// Room for the widest island plus its shadow. The transparent rest ignores the mouse.
    private static let panelSize = NSSize(width: 640, height: 140)

    func show(_ mode: OverlayModel.Mode) {
        hideTask?.cancel()
        hideTask = nil
        orderOutTask?.cancel()
        orderOutTask = nil
        if case .recording = mode {
            if case .recording = model.mode, model.isPresented {} else { model.resetLevels() }
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            // Render once tucked into the notch so the island visibly grows out of it.
            model.isPresented = false
            model.mode = mode
            position(panel)
            panel.orderFrontRegardless()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        } else {
            model.mode = mode
        }
        model.isPresented = true
    }

    func flash(_ text: String, isError: Bool = false, seconds: Double = 2.5) {
        show(.message(text, isError: isError))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible, model.isPresented else { return }
        model.isPresented = false
        orderOutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            self?.orderOutTask = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the menu bar, which the island spreads into.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// Pins the panel to the top center of the screen under the mouse and records its notch.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notch = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        } else {
            model.notch = nil
        }
        let size = Self.panelSize
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
            display: false)
    }
}

/// A borderless panel that may cover the menu bar, which AppKit otherwise keeps windows below.
private final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct IslandView: View {
    let model: OverlayModel

    /// The concave flare where the island meets the top edge of the screen.
    private static let ear: CGFloat = 6
    private static let outerPadding: CGFloat = 14
    private static let notchPadding: CGFloat = 8
    private static let waveformWidth = CGFloat(OverlayModel.barCount) * 4.5 - 2
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let maxMessageWidth: CGFloat = 320
    private static let messageLineHeight: CGFloat = 15

    var body: some View {
        let size = size
        let shape = IslandShape(ear: Self.ear, bottomRadius: bottomRadius)
        ZStack(alignment: .top) {
            shape.fill(.black)
            if model.isPresented {
                content
                    .id(kind)
                    .transition(.blurReplace)
            }
        }
        .frame(width: size.width + 2 * Self.ear, height: size.height, alignment: .top)
        .clipShape(shape)
        .shadow(color: .black.opacity(isExpanded ? 0.35 : 0), radius: 12, y: 4)
        .opacity(model.isPresented || model.notch != nil ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: model.isPresented)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.mode)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Content sits on either side of the notch, never under the camera.
            HStack(spacing: 0) {
                leading
                    .frame(width: wingWidth, alignment: .leading)
                    .padding(.leading, Self.outerPadding)
                    .padding(.trailing, Self.notchPadding)
                Color.clear.frame(width: model.notch?.width ?? 0)
                trailing
                    .frame(width: wingWidth, alignment: .trailing)
                    .padding(.leading, Self.notchPadding)
                    .padding(.trailing, Self.outerPadding)
            }
            .frame(height: rowHeight)
            detail
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch model.mode {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.7), radius: 3)
        case .working:
            Spinner()
        case .message:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.mode {
        case .recording:
            Waveform(levels: model.levels)
        case .working(let label):
            Text(label)
                .font(Font(Self.font))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
        case .message:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.mode {
        case .recording(handsFree: true):
            Text("Hands-free · press fn to finish")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: 20, alignment: .top)
                .transition(.blurReplace)
        case .message(let text, let isError):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "doc.on.clipboard")
                    .foregroundStyle(isError ? .yellow : .white.opacity(0.85))
                    .frame(width: 16)
                Text(text)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(width: messageSize.width, alignment: .leading)
            }
            .font(Font(Self.font))
            .frame(height: messageSize.height, alignment: .top)
        default:
            EmptyView()
        }
    }

    // MARK: - Geometry
    // Computed from the mode rather than measured from the content, so the shape springs smoothly
    // between modes instead of snapping when the outgoing content is removed.

    private var kind: Int {
        switch model.mode {
        case .recording: 0
        case .working: 1
        case .message: 2
        }
    }

    private var rowHeight: CGFloat { model.notch?.height ?? 32 }

    /// Width of the content on each side of the notch. Both sides match so the island stays centered.
    private var wingWidth: CGFloat {
        switch model.mode {
        case .recording: Self.waveformWidth
        case .working(let label): max(16, Self.textWidth(label))
        case .message: 0
        }
    }

    private var messageSize: CGSize {
        guard case .message(let text, _) = model.mode else { return .zero }
        let width = Self.textWidth(text)
        let lines: CGFloat = width > Self.maxMessageWidth ? 2 : 1
        return CGSize(width: min(width, Self.maxMessageWidth), height: lines * Self.messageLineHeight)
    }

    /// The island's size without its ears.
    private var size: CGSize {
        guard model.isPresented else {
            return model.notch.map { CGSize(width: $0.width - 2 * Self.ear, height: $0.height) }
                ?? CGSize(width: 120, height: 0)
        }
        var width = (model.notch?.width ?? 0) + 2 * (wingWidth + Self.outerPadding + Self.notchPadding)
        var height = rowHeight
        switch model.mode {
        case .recording(handsFree: true):
            height += 20
        case .message:
            width = max(width, messageSize.width + 22 + 2 * Self.outerPadding)
            height += messageSize.height + 12
        default:
            break
        }
        return CGSize(width: width, height: height)
    }

    private var isExpanded: Bool { model.isPresented && size.height > rowHeight }

    private var bottomRadius: CGFloat {
        guard model.isPresented else { return 8 }
        return isExpanded ? 18 : 12
    }

    private static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }
}

/// The notch silhouette: flush with the top of the screen, flaring out at the top corners and
/// rounded at the bottom.
private struct IslandShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ear = min(ear, rect.height / 2)
        let left = rect.minX + ear
        let right = rect.maxX - ear
        let radius = max(0, min(bottomRadius, rect.height - ear, (right - left) / 2))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + ear), control: CGPoint(x: left, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: radius)
        path.addLine(to: CGPoint(x: right, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// A white spinner. The system one renders dim gray on the black island.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0.2, to: 1)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(turn * 360))
        }
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2.5, height: 3 + CGFloat(levels[index]) * 13)
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.06), value: levels)
    }
}
