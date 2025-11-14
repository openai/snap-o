import SwiftUI

struct AdaptiveSideBySideLayout: Layout {
  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard subviews.count == 2 else { return .zero }

    let view1 = subviews[0].sizeThatFits(.unspecified)
    let view2 = subviews[1].sizeThatFits(.unspecified)

    let available = proposal.width ?? .infinity

    // Horizontal fits
    if view1.width + view2.width <= available {
      return CGSize(
        width: available,
        height: max(view1.height, view2.height)
      )
    }

    // Vertical layout
    return CGSize(
      width: available,
      height: view1.height + view2.height
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard subviews.count == 2 else { return }

    let aSize = subviews[0].sizeThatFits(.unspecified)
    let bSize = subviews[1].sizeThatFits(.unspecified)

    let available = bounds.width

    // --- Horizontal layout ---
    if aSize.width + bSize.width <= available {
      // Top-left for A (unchanged)
      subviews[0].place(
        at: bounds.origin,
        proposal: ProposedViewSize(width: aSize.width, height: aSize.height)
      )

      // Bottom-align B
      let rowHeight = max(aSize.height, bSize.height)
      let bY = bounds.minY + (rowHeight - bSize.height)

      subviews[1].place(
        at: CGPoint(x: bounds.maxX - bSize.width, y: bY),
        proposal: ProposedViewSize(width: bSize.width, height: bSize.height)
      )
      return
    }

    // --- Vertical fallback (unchanged) ---
    subviews[0].place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: available, height: aSize.height)
    )

    subviews[1].place(
      at: CGPoint(x: bounds.maxX - bSize.width, y: bounds.minY + aSize.height),
      proposal: ProposedViewSize(width: bSize.width, height: bSize.height)
    )
  }
}
