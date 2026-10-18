import SwiftUI

extension View {
    /// Scale native controls and their layout together. The editor uses WebKit's
    /// pageZoom for the same factor, so it must not also receive this transform.
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
