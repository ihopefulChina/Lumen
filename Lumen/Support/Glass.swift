import SwiftUI

enum Motion {
    static var settle: Animation { .spring(duration: 0.35, bounce: 0) }

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

extension View {
    @ViewBuilder
    func lumenGlass(in shape: some Shape = RoundedRectangle(cornerRadius: 16, style: .continuous)) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
