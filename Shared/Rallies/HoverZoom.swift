import SwiftUI

/// Magnifies a picture or video around a spot, to read a number or tell two players apart: on
/// the Mac while the pointer is over it, on iPhone and iPad while pinching. The spot under the
/// pointer (or between the fingers) stays put, like a loupe.
struct HoverZoom: ViewModifier {
    var enabled = true
    var scale: CGFloat = 2.5

    @State private var hover: CGPoint?
    @State private var pinch: (scale: CGFloat, anchor: UnitPoint)?

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let size = geo.size
            content
                .frame(width: size.width, height: size.height)
                .scaleEffect(currentScale, anchor: anchor(in: size))
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay {
                    if enabled {
                        #if os(macOS)
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point): hover = point
                                case .ended: hover = nil
                                }
                            }
                            .allowsHitTesting(true)
                        #else
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(MagnifyGesture()
                                .onChanged { value in
                                    pinch = (max(1, min(5, value.magnification * 1.5)), value.startAnchor)
                                }
                                .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { pinch = nil } })
                        #endif
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hover == nil)
        }
    }

    private var currentScale: CGFloat {
        guard enabled else { return 1 }
        if let pinch { return pinch.scale }
        return hover == nil ? 1 : scale
    }

    private func anchor(in size: CGSize) -> UnitPoint {
        if let pinch { return pinch.anchor }
        guard let hover, size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(x: hover.x / size.width, y: hover.y / size.height)
    }
}

extension View {
    /// See `HoverZoom`.
    func hoverZoom(_ enabled: Bool = true, scale: CGFloat = 2.5) -> some View {
        modifier(HoverZoom(enabled: enabled, scale: scale))
    }
}
