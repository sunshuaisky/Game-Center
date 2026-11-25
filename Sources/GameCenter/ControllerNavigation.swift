import Foundation

enum ControllerNavigationAction: Equatable {
    case moveHorizontal(Int)
    case moveVertical(Int)
    case confirm
}

struct ControllerNavigationEvent: Equatable {
    let id = UUID()
    let action: ControllerNavigationAction

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ControllerNavigation: ObservableObject {
    @Published private(set) var event: ControllerNavigationEvent?

    func send(_ action: ControllerNavigationAction) {
        event = ControllerNavigationEvent(action: action)
    }

    func reset() {
        event = nil
    }
}
