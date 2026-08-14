import SwiftUI

enum Motion {
    static var settle: Animation { .spring(duration: 0.35, bounce: 0) }
    static var flick: Animation { .spring(duration: 0.32, bounce: 0.18) }
    static var press: Animation { .easeOut(duration: 0.1) }

    static func run(_ reduceMotion: Bool, _ body: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, body)
        } else {
            withAnimation(settle, body)
        }
    }
}

struct PressStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder
    func lumenGlass(in shape: some Shape = RoundedRectangle(cornerRadius: 16, style: .continuous)) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func lumenChromeGlass() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            self.background(.bar, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    func lumenBackgroundExtension() -> some View {
        if #available(macOS 26, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }
}
