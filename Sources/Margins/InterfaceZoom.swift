import SwiftUI

private struct InterfaceZoomKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var interfaceZoom: Double {
        get { self[InterfaceZoomKey.self] }
        set { self[InterfaceZoomKey.self] = newValue }
    }
}

enum UITextStyle {
    case headline
    case body
    case callout
    case caption
    case caption2

    var baseSize: CGFloat {
        switch self {
        case .headline: return 13
        case .body: return 13
        case .callout: return 12
        case .caption: return 11
        case .caption2: return 10
        }
    }

    var defaultWeight: Font.Weight? {
        switch self {
        case .headline: return .semibold
        default: return nil
        }
    }
}

enum UITypography {
    static func font(_ style: UITextStyle, scale: Double, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        font(size: style.baseSize, scale: scale, weight: weight ?? style.defaultWeight, design: design)
    }

    static func font(size: CGFloat, scale: Double, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        .system(size: max(6, size * CGFloat(scale)), weight: weight ?? .regular, design: design)
    }

    static func controlSize(for scale: Double, compact: Bool = false) -> ControlSize {
        if compact {
            return scale >= 1.75 ? .regular : (scale >= 1.25 ? .small : .mini)
        }
        return scale >= 1.5 ? .large : (scale >= 1.1 ? .regular : .small)
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.interfaceZoom) private var zoom
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(UITypography.font(size: size, scale: zoom, weight: weight, design: design))
    }
}

extension View {
    func uiFont(_ style: UITextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: style.baseSize, weight: weight ?? style.defaultWeight, design: design))
    }

    func uiFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }

    /// Scale native toolbar controls and their layout together. Sidebar and inspector
    /// views use native scaled fonts via `interfaceZoom` so text stays crisp when zoomed.
    func interfaceZoom(_ scale: Double) -> some View {
        InterfaceZoomLayout(scale: scale) {
            scaleEffect(scale, anchor: .topLeading)
        }
    }
}

private struct InterfaceZoomLayout: Layout {
    let scale: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(unscaled(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: unscaled(ProposedViewSize(bounds.size)))
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale },
                         height: proposal.height.map { $0 / scale })
    }
}
