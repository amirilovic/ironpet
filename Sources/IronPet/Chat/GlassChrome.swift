import SwiftUI

/// Liquid Glass on macOS 26, blur materials on macOS 14 and 15.
/// Every macOS 26 call sits behind `#available` for older systems, and behind `#if compiler(>=6.2)` because
/// toolchains before Xcode 26 (CI's macos-15 runner) don't have the macOS 26 SDK and can't compile those calls.
extension View {
    /// Fills `shape` with glass (macOS 26) or a material with a hairline edge (earlier).
    @ViewBuilder
    func chromeGlass<S: InsettableShape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            materialFill(shape)
        }
        #else
        materialFill(shape)
        #endif
    }

    private func materialFill<S: InsettableShape>(_ shape: S) -> some View {
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
    }

    /// Pins `content` to `edge` over the scroll view. On macOS 26 it is a scroll-edge bar, so content
    /// scrolling under it fades and blurs into the glass; earlier it is a plain safe-area inset.
    @ViewBuilder
    func glassBar<V: View>(_ edge: VerticalEdge, @ViewBuilder content: () -> V) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.safeAreaBar(edge: edge, spacing: 0, content: content)
        } else {
            self.safeAreaInset(edge: edge, spacing: 0, content: content)
        }
        #else
        self.safeAreaInset(edge: edge, spacing: 0, content: content)
        #endif
    }

    /// Content passing under the header and composer blurs and fades instead of being cut off at a line.
    @ViewBuilder
    func softScrollEdges() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Glass that reacts to the pointer on macOS 26; the same material as `chromeGlass` earlier.
    @ViewBuilder
    func interactiveGlass<S: InsettableShape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            materialFill(shape)
        }
        #else
        materialFill(shape)
        #endif
    }

    /// A filled circle in `color`, tinted glass on macOS 26.
    @ViewBuilder
    func tintedCircle(_ color: Color) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(color).interactive(), in: Circle())
        } else {
            self.background(color, in: Circle())
        }
        #else
        self.background(color, in: Circle())
        #endif
    }
}

/// Wraps neighbouring glass shapes so they sample and blend together on macOS 26.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct CircleHoverIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration)
    }

    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .pointerCursor()
        }
    }
}

/// A free-standing round glass button, like Telegram's attach and mic buttons. The icon colour is set here, not
/// left to the glass style, so it stays readable in light and dark mode.
struct GlassCircleButtonStyle: ButtonStyle {
    static let size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
            .interactiveGlass(in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .pointerCursor()
    }
}

/// Shows the pointing-hand cursor while the mouse is over the view. The cursor is pushed on entry and popped on exit
/// or when the view leaves the hierarchy, so a button that disappears under the mouse cannot leave it stuck.
private struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                sync()
            }
            .onChange(of: isEnabled) { sync() }
            .onDisappear {
                hovering = false
                sync()
            }
    }

    /// Pushes the hand while the mouse is inside an enabled view, and pops it as soon as either stops being true.
    private func sync() {
        let want = hovering && isEnabled
        if want && !pushed {
            pushed = true
            NSCursor.pointingHand.push()
        } else if !want && pushed {
            pushed = false
            NSCursor.pop()
        }
    }
}

extension View {
    /// The pointing-hand cursor over this view, for buttons and other clickable chrome in the chat.
    func pointerCursor() -> some View { modifier(PointerCursorModifier()) }
}
