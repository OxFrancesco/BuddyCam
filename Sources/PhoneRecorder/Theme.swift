import AppKit
import CoreText
import SwiftUI

// Design tokens from oddofrancesco.com/design: pure black, white outlines,
// one coral accent, hard offset shadows, zero radius, mechanical motion.
enum Theme {
    static let background = Color.black
    static let card = Color.black
    static let foreground = Color.white
    static let primary = Color(red: 214 / 255, green: 84 / 255, blue: 75 / 255)
    static let hairline = Color.white.opacity(0.28)

    static let hover = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
}

enum Fonts {
    static let displayFamily = "Chakra Petch"
    static let monoFamily = "IBM Plex Mono"

    static func register() {
        let roots = [Bundle.main.resourceURL,
                     Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Fonts", isDirectory: true)]
        for root in roots.compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "ttf" {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
    }

    static func display(_ size: CGFloat) -> Font { .custom(displayFamily, size: size) }
    static func mono(_ size: CGFloat) -> Font { .custom(monoFamily, size: size) }
}

extension View {
    func brutalOutline(_ width: CGFloat = 3, color: Color = Theme.foreground) -> some View {
        overlay(Rectangle().strokeBorder(color, lineWidth: width))
    }

    func hardShadow(_ offset: CGFloat = 4, color: Color = Theme.foreground) -> some View {
        background(Rectangle().fill(color).offset(x: offset, y: offset))
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Fonts.mono(10)).fontWeight(.bold).tracking(1.4)
            .foregroundStyle(Theme.foreground.opacity(0.7))
    }
}

struct MonoText: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Theme.foreground
    init(_ text: String, size: CGFloat = 12, color: Color = Theme.foreground) {
        self.text = text; self.size = size; self.color = color
    }
    var body: some View {
        Text(text).font(Fonts.mono(size)).foregroundStyle(color)
    }
}

struct BrutalButtonStyle: ButtonStyle {
    enum Variant { case fill, outline, ghost }
    var variant: Variant = .outline
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        Inner(variant: variant, height: height, configuration: configuration)
    }

    struct Inner: View {
        let variant: Variant
        let height: CGFloat
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        private var pressed: Bool { configuration.isPressed }
        private var lift: CGFloat { pressed ? 4 : (hovering && variant == .fill ? -2 : 0) }
        private var shadow: CGFloat {
            switch variant {
            case .fill, .outline: return pressed ? 0 : (hovering && variant == .fill ? 6 : 4)
            case .ghost: return 0
            }
        }
        private var ink: Color {
            switch variant {
            case .fill: return Theme.background
            case .outline, .ghost: return hovering ? Theme.primary : Theme.foreground
            }
        }

        var body: some View {
            configuration.label
                .font(Fonts.mono(12)).fontWeight(.bold).tracking(0.6)
                .textCase(.uppercase)
                .padding(.horizontal, variant == .ghost ? 4 : 16)
                .frame(height: height)
                .foregroundStyle(ink)
                .background(variant == .fill ? Theme.primary : Theme.card)
                .overlay {
                    if variant != .ghost {
                        Rectangle().strokeBorder(hovering || variant == .fill ? Theme.primary : Theme.foreground, lineWidth: 3)
                    }
                }
                .background {
                    if shadow > 0 {
                        Rectangle().fill(variant == .fill && hovering ? Theme.primary : Theme.foreground)
                            .offset(x: shadow, y: shadow)
                    }
                }
                .offset(x: lift, y: lift)
                .opacity(enabled ? 1 : 0.4)
                .animation(Theme.hover, value: hovering)
                .animation(Theme.press, value: pressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == BrutalButtonStyle {
    static var brutal: BrutalButtonStyle { BrutalButtonStyle() }
    static var brutalFill: BrutalButtonStyle { BrutalButtonStyle(variant: .fill) }
    static var brutalGhost: BrutalButtonStyle { BrutalButtonStyle(variant: .ghost) }
}

struct SegmentedControl<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var height: CGFloat = 34
    @State private var hovering: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    selection = option.1
                } label: {
                    Text(option.0)
                        .font(Fonts.mono(11)).fontWeight(.bold).tracking(0.55)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity).frame(height: height)
                        .foregroundStyle(selection == option.1 ? Theme.background : (hovering == index ? Theme.primary : Theme.foreground))
                        .background(selection == option.1 ? Theme.primary : Theme.card)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 ? index : nil }
                if index < options.count - 1 {
                    Rectangle().fill(Theme.foreground).frame(width: 2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .brutalOutline(2)
        .animation(Theme.press, value: selection)
    }
}

struct MenuField: View {
    let value: String
    let placeholder: String
    @ViewBuilder var items: () -> AnyView
    @State private var hovering = false

    init(value: String, placeholder: String = "Select", @ViewBuilder items: @escaping () -> some View) {
        self.value = value
        self.placeholder = placeholder
        self.items = { AnyView(items()) }
    }

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                Text(value.isEmpty ? placeholder : value)
                    .font(Fonts.mono(12))
                    .foregroundStyle(value.isEmpty ? Theme.foreground.opacity(0.5) : Theme.foreground)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.foreground.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .frame(height: 36).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .brutalOutline(3, color: hovering ? Theme.primary : Theme.foreground)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
    }
}

struct BrutalField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Fonts.mono(12))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.card)
            .brutalOutline(3, color: focused ? Theme.primary : Theme.foreground)
            .hardShadow(focused ? 4 : 0, color: Theme.primary)
            .animation(Theme.hover, value: focused)
    }
}

struct StatusDot: View {
    var body: some View {
        Rectangle()
            .fill(Theme.primary)
            .frame(width: 8, height: 8)
            .phaseAnimator([false, true]) { view, phase in
                view.opacity(phase ? 0.3 : 1)
            } animation: { _ in
                .linear(duration: 0.8)
            }
            .accessibilityHidden(true)
    }
}
