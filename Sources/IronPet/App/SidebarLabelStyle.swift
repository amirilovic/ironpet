import SwiftUI

/// Finder-like sidebar row: the icon sits centred in a fixed-width column, so
/// every label starts at the same x whatever the symbol's width.
struct SidebarLabelStyle: LabelStyle {
    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Self.spacing) {
            configuration.icon
                .frame(width: Self.iconWidth, alignment: .center)
            configuration.title
        }
    }
}

extension LabelStyle where Self == SidebarLabelStyle {
    static var ironPetSidebar: SidebarLabelStyle { SidebarLabelStyle() }
}
