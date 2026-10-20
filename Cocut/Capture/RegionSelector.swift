import AppKit
import SwiftUI

// MARK: - Shared selection state

enum AspectPreset: String, CaseIterable, Identifiable, Codable {
    case widescreen = "16:9"
    case standard = "4:3"
    case free = "Free"

    var id: String { rawValue }

    var ratio: CGFloat? {
        switch self {
        case .widescreen: return 16.0 / 9.0
        case .standard: return 4.0 / 3.0
        case .free: return nil
        }
    }
}

@MainActor
@Observable
final class SelectionState {
    var displayID: CGDirectDisplayID?
    var rect: CGRect?
    var aspect: AspectPreset = .widescreen
    var mode: CaptureMode = .auto
    var captureAudio = true

    @ObservationIgnored var onConfirm: @MainActor () -> Void = {}
    @ObservationIgnored var onCancel: @MainActor () -> Void = {}
}

// MARK: - Controller

/// Puts a dimmed overlay on every screen and lets the user drag out a region.
@MainActor
final class RegionSelectionController {
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var continuation: CheckedContinuation<CaptureRegion?, Never>?
    private var state = SelectionState()

    static let minimumSize: CGFloat = 24

    func selectRegion(initial: CaptureRegion?, aspect: AspectPreset, mode: CaptureMode,
                      captureAudio: Bool) async -> CaptureRegion? {
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.present(initial: initial, aspect: aspect, mode: mode, captureAudio: captureAudio)
        }
    }

    var currentAspect: AspectPreset { state.aspect }
    var currentMode: CaptureMode { state.mode }
    var currentCaptureAudio: Bool { state.captureAudio }

    private func present(initial: CaptureRegion?, aspect: AspectPreset, mode: CaptureMode, captureAudio: Bool) {
        let state = SelectionState()
        state.aspect = aspect
        state.mode = mode
        state.captureAudio = captureAudio
        if let initial, initial.screen != nil {
            state.displayID = initial.displayID
            state.rect = initial.rect
        }
        state.onConfirm = { [weak self] in self?.confirm() }
        state.onCancel = { [weak self] in self?.finish(nil) }
        self.state = state

        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let window = OverlayWindow(screen: screen)
            let root = SelectionOverlayView(
                displayID: id,
                bounds: screen.frame.size,
                scale: screen.backingScaleFactor,
                state: state
            )
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            window.contentView = hosting
            window.orderFrontRegardless()
            windows.append(window)
        }

        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self else { return event }
                switch event.keyCode {
                case 53: // esc
                    self.finish(nil)
                    return nil
                case 36, 76: // return, enter
                    self.confirm()
                    return nil
                default:
                    return event
                }
            }
        }
    }

    private func confirm() {
        guard let id = state.displayID, let rect = state.rect,
              rect.width >= Self.minimumSize, rect.height >= Self.minimumSize else {
            NSSound.beep()
            return
        }
        finish(CaptureRegion(displayID: id, rect: rect.integral))
    }

    private func finish(_ region: CaptureRegion?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        continuation?.resume(returning: region)
        continuation = nil
    }
}

/// Borderless, transparent window that covers one screen.
/// A non-activating panel: it takes keyboard input without activating Cocut, so selecting a
/// region over a browser in fullscreen doesn't switch Spaces away from the video.
final class OverlayWindow: NSPanel {
    convenience init(screen: NSScreen, interactive: Bool = true) {
        self.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = !interactive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay view

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    var opposite: Corner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

private enum DragMode {
    case create(anchor: CGPoint)
    case move(original: CGRect)
    case resize(anchor: CGPoint)
}

struct SelectionOverlayView: View {
    let displayID: CGDirectDisplayID
    let bounds: CGSize
    let scale: CGFloat
    @Bindable var state: SelectionState

    @State private var drag: DragMode?

    private let space = "overlay"

    private var activeRect: CGRect? {
        state.displayID == displayID ? state.rect : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming
                .contentShape(Rectangle())
                .gesture(canvasGesture)
                .pointerStyle(.rectSelection)

            if let rect = activeRect {
                selectionChrome(rect)
            } else {
                hint
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .coordinateSpace(.named(space))
        .onChange(of: state.aspect) { _, newValue in
            applyAspect(newValue)
        }
    }

    // MARK: Pieces

    private var dimming: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: bounds))
            if let rect = activeRect { path.addRect(rect) }
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 34, weight: .light))
            Text("Drag to select the video")
                .font(.title3.weight(.semibold))
            Text("Tip: stay inside the picture, above the player's controls")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Return to start  ·  Esc to cancel")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 5) {
                Text("While recording, click the video once, then control it from the keyboard:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                KeyHints()
            }
            .padding(.top, 6)
            Button {
                selectFullScreen()
            } label: {
                Label("Use Full Screen", systemImage: "rectangle.dashed")
            }
            .controlSize(.large)
            .padding(.top, 4)
            .help("Record this whole display")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: bounds.width / 2, y: bounds.height / 2)
    }

    @ViewBuilder
    private func selectionChrome(_ rect: CGRect) -> some View {
        // Border
        Rectangle()
            .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
            .background(Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 4).blur(radius: 3))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)

        // Rule-of-thirds guides while dragging
        if drag != nil {
            thirds(rect)
        }

        // Size readout
        Text("\(Int(rect.width * scale)) × \(Int(rect.height * scale))")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .fixedSize()
            .position(x: rect.midX, y: max(rect.minY - 18, 16))
            .allowsHitTesting(false)

        // Corner handles
        ForEach(Corner.allCases, id: \.self) { corner in
            handle(for: corner, in: rect)
        }

        // Controls
        if drag == nil {
            controlBar
                .position(controlBarPosition(for: rect))
                .transition(.opacity)
        }
    }

    private func thirds(_ rect: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
        .allowsHitTesting(false)
    }

    private func handle(for corner: Corner, in rect: CGRect) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .position(corner.point(in: rect))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        if drag == nil, let current = activeRect {
                            drag = .resize(anchor: corner.opposite.point(in: current))
                        }
                        if case .resize(let anchor) = drag {
                            state.rect = rectFrom(anchor: anchor, to: value.location)
                        }
                    }
                    .onEnded { _ in endDrag() }
            )
            .pointerStyle(.rectSelection)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("Aspect", selection: $state.aspect) {
                ForEach(AspectPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)

            Button {
                selectFullScreen()
            } label: {
                Image(systemName: "rectangle.dashed")
            }
            .buttonStyle(.borderless)
            .help("Select the whole display")

            Divider().frame(height: 22)

            Toggle(isOn: Binding(
                get: { state.mode == .auto },
                set: { state.mode = $0 ? .auto : .manual }
            )) {
                Text("Record when video plays")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Cocut waits for the video to move: play starts a clip, pause ends it. Turn off to record immediately.")

            Toggle(isOn: $state.captureAudio) {
                Image(systemName: state.captureAudio ? "speaker.wave.2.fill" : "speaker.slash")
                    .frame(width: 18)
            }
            .toggleStyle(.button)
            .help(state.captureAudio ? "Recording the video's sound. Click to record silent clips." : "Recording without sound. Click to include the video's sound.")

            Divider().frame(height: 22)

            Button("Cancel") { state.onCancel() }
                .buttonStyle(.borderless)
                .controlSize(.large)

            Button {
                state.onConfirm()
            } label: {
                Label(state.mode == .auto ? "Start" : "Record",
                      systemImage: state.mode == .auto ? "play.circle.fill" : "record.circle.fill")
            }
            .buttonStyle(SolidButtonStyle(tint: Design.record))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
    }

    private func controlBarPosition(for rect: CGRect) -> CGPoint {
        let barHalfWidth: CGFloat = 375
        let x = min(max(rect.midX, barHalfWidth + 12), bounds.width - barHalfWidth - 12)
        let gap: CGFloat = 36
        let y: CGFloat
        if rect.maxY + gap + 30 < bounds.height {
            y = rect.maxY + gap
        } else if rect.minY - gap - 30 > 0 {
            y = rect.minY - gap - 14
        } else {
            // Region fills the screen: float above the Dock area.
            y = bounds.height - 140
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: Gestures & geometry

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                if drag == nil {
                    if let rect = activeRect, rect.contains(value.startLocation) {
                        drag = .move(original: rect)
                    } else {
                        drag = .create(anchor: clamp(value.startLocation))
                        state.displayID = displayID
                        state.rect = nil
                    }
                }
                switch drag {
                case .create(let anchor):
                    state.rect = rectFrom(anchor: anchor, to: value.location)
                case .move(let original):
                    state.rect = moved(original, by: value.translation)
                default:
                    break
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func selectFullScreen() {
        state.aspect = .free
        state.displayID = displayID
        withAnimation(.snappy(duration: 0.2)) {
            state.rect = CGRect(origin: .zero, size: bounds)
        }
    }

    private func endDrag() {
        if let rect = state.rect, state.displayID == displayID,
           rect.width < RegionSelectionController.minimumSize || rect.height < RegionSelectionController.minimumSize {
            state.rect = nil
        }
        withAnimation(.easeOut(duration: 0.15)) { drag = nil }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func rectFrom(anchor a: CGPoint, to point: CGPoint) -> CGRect {
        let p = clamp(point)
        var w = p.x - a.x
        var h = p.y - a.y

        if let ratio = state.aspect.ratio {
            let sx: CGFloat = w < 0 ? -1 : 1
            let sy: CGFloat = h < 0 ? -1 : 1
            var aw = abs(w)
            var ah = abs(h)
            if aw / ratio > ah { ah = aw / ratio } else { aw = ah * ratio }
            let maxW = sx > 0 ? bounds.width - a.x : a.x
            let maxH = sy > 0 ? bounds.height - a.y : a.y
            if aw > maxW { aw = maxW; ah = aw / ratio }
            if ah > maxH { ah = maxH; aw = ah * ratio }
            w = aw * sx
            h = ah * sy
        }

        return CGRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h), width: abs(w), height: abs(h))
    }

    private func moved(_ rect: CGRect, by t: CGSize) -> CGRect {
        var r = rect.offsetBy(dx: t.width, dy: t.height)
        r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
        r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
        return r
    }

    private func applyAspect(_ preset: AspectPreset) {
        guard let rect = activeRect, let ratio = preset.ratio else { return }
        var w = rect.width
        var h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        var r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
        r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
        withAnimation(.snappy(duration: 0.2)) { state.rect = r }
    }
}
