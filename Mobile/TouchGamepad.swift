import SwiftUI
import UIKit

// MARK: - Edge-to-Edge Fullscreen Geometry Reader

private struct SafeAreaInsetsPreferenceKey: PreferenceKey {
    static var defaultValue = EdgeInsets()
    static func reduce(value: inout EdgeInsets, nextValue: () -> EdgeInsets) {
        let next = nextValue()
        if next != EdgeInsets() || value == EdgeInsets() {
            value = next
        }
    }
}

/// Provides the true physical edge-to-edge screen size alongside the real device safe area insets.
/// Prevents black safe-area letterboxing in landscape (Dynamic Island / rounded edges)
/// and portrait (status bar / home indicator) while keeping interactive controls safely inset.
struct FullScreenReader<Content: View>: View {
    @ViewBuilder let content: (_ fullSize: CGSize, _ safeInsets: EdgeInsets) -> Content
    @State private var safeInsets = EdgeInsets()

    var body: some View {
        ZStack {
            GeometryReader { safeProxy in
                Color.clear
                    .preference(key: SafeAreaInsetsPreferenceKey.self, value: safeProxy.safeAreaInsets)
            }
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(false)

            GeometryReader { fullProxy in
                content(fullProxy.size, safeInsets)
                    .frame(width: fullProxy.size.width, height: fullProxy.size.height)
            }
            .ignoresSafeArea()
        }
        .onPreferenceChange(SafeAreaInsetsPreferenceKey.self) { next in
            if next != safeInsets {
                safeInsets = next
            }
        }
    }
}

/// Crisp tactile press feedback for iOS controls (respects Reduce Motion).
struct PhoneTactileButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    var pressedOpacity: Double = 0.86
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

/// Direct CALayer frame host for software-rendered Libretro cores.
/// Updating `layer.contents` directly avoids triggering SwiftUI body diffs at 60fps
/// and keeps touch controls responsive even when emulation frame times fluctuate.
final class RetroScreenUIView: UIView {
    var onPointer: ((CGFloat, CGFloat, Bool) -> Void)?
    private var activeTouch: UITouch?
    private var frameSize: CGSize = .zero
    private let imageLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = false
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageLayer.frame = bounds
    }

    func update(image: CGImage) {
        frameSize = CGSize(width: image.width, height: image.height)
        imageLayer.contents = image
    }

    private func report(_ touch: UITouch, pressed: Bool) {
        guard pressed, frameSize.width > 0, frameSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            onPointer?(0, 0, false)
            return
        }
        let point = touch.location(in: self)
        let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let renderedWidth = frameSize.width * scale
        let renderedHeight = frameSize.height * scale
        let x = (point.x - (bounds.width - renderedWidth) / 2) / max(1, renderedWidth)
        let y = (point.y - (bounds.height - renderedHeight) / 2) / max(1, renderedHeight)
        onPointer?(x, y, (0...1).contains(x) && (0...1).contains(y))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        report(touch, pressed: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        report(activeTouch, pressed: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        report(activeTouch, pressed: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        report(activeTouch, pressed: false)
    }
}

struct RetroScreenView: UIViewRepresentable {
    let view: RetroScreenUIView
    func makeUIView(context: Context) -> RetroScreenUIView { view }
    func updateUIView(_ uiView: RetroScreenUIView, context: Context) {}
}

// MARK: - Single Multi-Touch Virtual Button

final class PadButtonUIView: UIView {
    private let label = UILabel()
    private var activeTouches = Set<UITouch>()
    private var isPressedState = false
    var onChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = UIColor(white: 0.09, alpha: 0.42)
        layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        label.textColor = UIColor.white.withAlphaComponent(0.95)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.isUserInteractionEnabled = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        guard label.text != title else { return }
        label.text = title
        accessibilityLabel = title
        accessibilityTraits = .button
        isAccessibilityElement = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 4, dy: 2)
        layer.cornerRadius = min(16, bounds.height / 2)
    }

    private func setPressed(_ pressed: Bool) {
        guard isPressedState != pressed else { return }
        isPressedState = pressed
        if pressed { TouchPadHaptics.tap() }
        backgroundColor = pressed
            ? UIColor.white.withAlphaComponent(0.38)
            : UIColor(white: 0.09, alpha: 0.42)
        layer.borderColor = UIColor.white.withAlphaComponent(pressed ? 0.65 : 0.24).cgColor
        transform = pressed ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
        onChange?(pressed)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        setPressed(!activeTouches.isEmpty)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        setPressed(!activeTouches.isEmpty)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        setPressed(!activeTouches.isEmpty)
    }
}

struct TouchPadButton: UIViewRepresentable {
    let title: String
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> PadButtonUIView {
        let view = PadButtonUIView()
        view.configure(title: title, onChange: onChange)
        return view
    }

    func updateUIView(_ uiView: PadButtonUIView, context: Context) {
        uiView.configure(title: title, onChange: onChange)
    }
}

// MARK: - 8-Way Sliding Multi-Touch D-Pad

final class TouchDPadUIView: UIView {
    struct State: Equatable {
        var up = false, down = false, left = false, right = false
    }

    var onChange: ((State) -> Void)?
    private var activeTouches = Set<UITouch>()
    private var current = State()
    private let upCell = UILabel(), downCell = UILabel(), leftCell = UILabel(), rightCell = UILabel()
    private let centerCap = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        for (cell, text) in [(upCell, "▲"), (downCell, "▼"), (leftCell, "◀"), (rightCell, "▶")] {
            cell.text = text
            cell.textColor = UIColor.white.withAlphaComponent(0.92)
            cell.font = .systemFont(ofSize: 13, weight: .bold)
            cell.textAlignment = .center
            cell.backgroundColor = UIColor(white: 0.09, alpha: 0.44)
            cell.layer.cornerRadius = 11
            cell.layer.masksToBounds = true
            cell.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
            cell.layer.borderWidth = 1
            cell.isUserInteractionEnabled = false
            addSubview(cell)
        }
        centerCap.backgroundColor = UIColor(white: 0.09, alpha: 0.32)
        centerCap.layer.cornerRadius = 10
        centerCap.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        centerCap.layer.borderWidth = 1
        centerCap.isUserInteractionEnabled = false
        addSubview(centerCap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let cell = side / 3
        let ox = (bounds.width - side) / 2
        let oy = (bounds.height - side) / 2
        upCell.frame = CGRect(x: ox + cell, y: oy, width: cell, height: cell).insetBy(dx: 2, dy: 2)
        downCell.frame = CGRect(x: ox + cell, y: oy + cell * 2, width: cell, height: cell).insetBy(dx: 2, dy: 2)
        leftCell.frame = CGRect(x: ox, y: oy + cell, width: cell, height: cell).insetBy(dx: 2, dy: 2)
        rightCell.frame = CGRect(x: ox + cell * 2, y: oy + cell, width: cell, height: cell).insetBy(dx: 2, dy: 2)
        centerCap.frame = CGRect(x: ox + cell, y: oy + cell, width: cell, height: cell).insetBy(dx: 5, dy: 5)
    }

    private func recompute() {
        var next = State()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let deadzone = min(bounds.width, bounds.height) * 0.12
        for touch in activeTouches {
            let p = touch.location(in: self)
            let dx = p.x - center.x
            let dy = p.y - center.y
            let dist = hypot(dx, dy)
            guard dist >= deadzone else { continue }
            let angle = atan2(dy, dx) * 180 / .pi // -180..180, 0=right, 90=down, -90=up
            if angle >= -67.5 && angle <= 67.5 { next.right = true }
            if angle >= 112.5 || angle <= -112.5 { next.left = true }
            if angle >= 22.5 && angle <= 157.5 { next.down = true }
            if angle <= -22.5 && angle >= -157.5 { next.up = true }
        }
        if next != current {
            let pressedAnyNew = (next.up && !current.up) || (next.down && !current.down)
                || (next.left && !current.left) || (next.right && !current.right)
            if pressedAnyNew { TouchPadHaptics.tap() }
            current = next
            updateHighlights()
            onChange?(next)
        }
    }

    private func updateHighlights() {
        let restBg = UIColor(white: 0.09, alpha: 0.44)
        let activeBg = UIColor.white.withAlphaComponent(0.42)
        let restBorder = UIColor.white.withAlphaComponent(0.22).cgColor
        let activeBorder = UIColor.white.withAlphaComponent(0.68).cgColor
        for (cell, active) in [(upCell, current.up), (downCell, current.down), (leftCell, current.left), (rightCell, current.right)] {
            cell.backgroundColor = active ? activeBg : restBg
            cell.layer.borderColor = active ? activeBorder : restBorder
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        recompute()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        recompute()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        recompute()
    }
}

struct TouchDPad: UIViewRepresentable {
    let onChange: (TouchDPadUIView.State) -> Void
    func makeUIView(context: Context) -> TouchDPadUIView {
        let view = TouchDPadUIView()
        view.onChange = onChange
        return view
    }
    func updateUIView(_ uiView: TouchDPadUIView, context: Context) {
        uiView.onChange = onChange
    }
}

// MARK: - Multi-Touch Diamond Action Pad (Supports Rolling Thumb & Simultaneous Multi-Button)

final class TouchDiamondPadUIView: UIView {
    struct Labels: Equatable {
        let top: String?
        let left: String?
        let right: String?
        let bottom: String?
    }

    struct State: Equatable {
        var top = false, left = false, right = false, bottom = false
    }

    var onChange: ((State) -> Void)?
    private var labels = Labels(top: "X", left: "Y", right: "A", bottom: "B")
    private var activeTouches = Set<UITouch>()
    private var current = State()
    private let topView = UILabel(), leftView = UILabel(), rightView = UILabel(), bottomView = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        for cell in [topView, leftView, rightView, bottomView] {
            cell.textColor = UIColor.white.withAlphaComponent(0.95)
            cell.font = .systemFont(ofSize: 17, weight: .bold)
            cell.textAlignment = .center
            cell.backgroundColor = UIColor(white: 0.09, alpha: 0.46)
            cell.layer.borderColor = UIColor.white.withAlphaComponent(0.26).cgColor
            cell.layer.borderWidth = 1
            cell.layer.masksToBounds = true
            cell.isUserInteractionEnabled = false
            addSubview(cell)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(labels: Labels, onChange: @escaping (State) -> Void) {
        self.onChange = onChange
        guard self.labels != labels else { return }
        self.labels = labels
        topView.text = labels.top; topView.isHidden = labels.top == nil
        leftView.text = labels.left; leftView.isHidden = labels.left == nil
        rightView.text = labels.right; rightView.isHidden = labels.right == nil
        bottomView.text = labels.bottom; bottomView.isHidden = labels.bottom == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let ox = (bounds.width - side) / 2
        let oy = (bounds.height - side) / 2
        let twoButtonOnly = labels.top == nil && labels.left == nil && labels.right != nil && labels.bottom != nil
        if twoButtonOnly {
            let d = side * 0.44
            bottomView.frame = CGRect(x: ox + side * 0.06, y: oy + side * 0.46, width: d, height: d)
            rightView.frame = CGRect(x: ox + side * 0.50, y: oy + side * 0.14, width: d, height: d)
            topView.frame = .zero
            leftView.frame = .zero
        } else {
            let d = side * 0.36
            let midX = ox + (side - d) / 2
            let midY = oy + (side - d) / 2
            topView.frame = CGRect(x: midX, y: oy + 2, width: d, height: d)
            bottomView.frame = CGRect(x: midX, y: oy + side - d - 2, width: d, height: d)
            leftView.frame = CGRect(x: ox + 2, y: midY, width: d, height: d)
            rightView.frame = CGRect(x: ox + side - d - 2, y: midY, width: d, height: d)
        }
        for cell in [topView, leftView, rightView, bottomView] {
            cell.layer.cornerRadius = cell.bounds.width / 2
        }
    }

    private func recompute() {
        var next = State()
        let refWidth: CGFloat = !rightView.isHidden && rightView.bounds.width > 1
            ? rightView.bounds.width
            : (!bottomView.isHidden && bottomView.bounds.width > 1 ? bottomView.bounds.width : 44)
        let hitRadius = max(28, refWidth * 0.66)
        let hitRadiusSq = hitRadius * hitRadius
        let fallbackRadiusSq = (hitRadius * 1.45) * (hitRadius * 1.45)

        for touch in activeTouches {
            let p = touch.location(in: self)
            var matchedAny = false
            var nearestDistSq = CGFloat.greatestFiniteMagnitude
            var nearestIndex = -1

            func test(_ view: UILabel, index: Int) -> Bool {
                guard !view.isHidden && view.bounds.width > 1 else { return false }
                let dx = p.x - view.center.x
                let dy = p.y - view.center.y
                let distSq = dx * dx + dy * dy
                if distSq < nearestDistSq {
                    nearestDistSq = distSq
                    nearestIndex = index
                }
                if distSq <= hitRadiusSq {
                    matchedAny = true
                    return true
                }
                return false
            }

            if test(topView, index: 0) { next.top = true }
            if test(leftView, index: 1) { next.left = true }
            if test(rightView, index: 2) { next.right = true }
            if test(bottomView, index: 3) { next.bottom = true }

            if !matchedAny && nearestDistSq <= fallbackRadiusSq {
                switch nearestIndex {
                case 0: next.top = true
                case 1: next.left = true
                case 2: next.right = true
                case 3: next.bottom = true
                default: break
                }
            }
        }
        if next != current {
            let pressedAnyNew = (next.top && !current.top) || (next.left && !current.left)
                || (next.right && !current.right) || (next.bottom && !current.bottom)
            if pressedAnyNew { TouchPadHaptics.tap() }
            current = next
            updateHighlights()
            onChange?(next)
        }
    }

    private func updateHighlights() {
        let restBg = UIColor(white: 0.09, alpha: 0.46)
        let activeBg = UIColor.white.withAlphaComponent(0.44)
        let restBorder = UIColor.white.withAlphaComponent(0.26).cgColor
        let activeBorder = UIColor.white.withAlphaComponent(0.72).cgColor
        for (cell, active) in [(topView, current.top), (leftView, current.left), (rightView, current.right), (bottomView, current.bottom)] {
            cell.backgroundColor = active ? activeBg : restBg
            cell.layer.borderColor = active ? activeBorder : restBorder
            cell.transform = active ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.formUnion(touches)
        recompute()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        recompute()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        recompute()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        recompute()
    }
}

struct TouchDiamondPad: UIViewRepresentable {
    let labels: TouchDiamondPadUIView.Labels
    let onChange: (TouchDiamondPadUIView.State) -> Void

    func makeUIView(context: Context) -> TouchDiamondPadUIView {
        let view = TouchDiamondPadUIView()
        view.configure(labels: labels, onChange: onChange)
        return view
    }

    func updateUIView(_ uiView: TouchDiamondPadUIView, context: Context) {
        uiView.configure(labels: labels, onChange: onChange)
    }
}

// MARK: - Multi-Touch Analog Stick

final class TouchAnalogStickUIView: UIView {
    var invertY = false
    var onChange: ((Float, Float) -> Void)?
    private var activeTouch: UITouch?
    private let baseView = UIView()
    private let knobView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        baseView.backgroundColor = UIColor(white: 0.09, alpha: 0.42)
        baseView.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        baseView.layer.borderWidth = 1
        baseView.isUserInteractionEnabled = false
        addSubview(baseView)

        knobView.backgroundColor = UIColor.white.withAlphaComponent(0.42)
        knobView.layer.borderColor = UIColor.white.withAlphaComponent(0.55).cgColor
        knobView.layer.borderWidth = 1
        knobView.layer.shadowColor = UIColor.black.cgColor
        knobView.layer.shadowOpacity = 0.35
        knobView.layer.shadowRadius = 4
        knobView.layer.shadowOffset = CGSize(width: 0, height: 2)
        knobView.isUserInteractionEnabled = false
        addSubview(knobView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        baseView.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        baseView.layer.cornerRadius = side / 2
        let knob = side * 0.40
        knobView.bounds = CGRect(x: 0, y: 0, width: knob, height: knob)
        knobView.layer.cornerRadius = knob / 2
        if activeTouch == nil {
            knobView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private func updateStick(for touch: UITouch?) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let touch else {
            UIView.animate(withDuration: 0.14, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.knobView.center = center
                self.knobView.backgroundColor = UIColor.white.withAlphaComponent(0.42)
            }
            onChange?(0, 0)
            return
        }
        let maxRadius = max(16, min(bounds.width, bounds.height) * 0.36)
        let point = touch.location(in: self)
        var dx = point.x - center.x
        var dy = point.y - center.y
        let dist = hypot(dx, dy)
        if dist > maxRadius {
            dx = dx / dist * maxRadius
            dy = dy / dist * maxRadius
        }
        knobView.center = CGPoint(x: center.x + dx, y: center.y + dy)
        knobView.backgroundColor = UIColor.white.withAlphaComponent(0.62)
        let nx = Float(dx / maxRadius)
        let ny = Float((invertY ? -dy : dy) / maxRadius)
        onChange?(nx, ny)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        updateStick(for: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        updateStick(for: activeTouch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        updateStick(for: nil)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        updateStick(for: nil)
    }
}

struct TouchAnalogStick: UIViewRepresentable {
    var invertY: Bool = false
    let onChange: (Float, Float) -> Void

    func makeUIView(context: Context) -> TouchAnalogStickUIView {
        let view = TouchAnalogStickUIView()
        view.invertY = invertY
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: TouchAnalogStickUIView, context: Context) {
        uiView.invertY = invertY
        uiView.onChange = onChange
    }
}

// MARK: - Shared Haptics & Player HUD Components

@MainActor
enum TouchPadHaptics {
    static let defaultsKey = "phone.player.haptics"
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    private static var cachedEnabled: Bool = {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }()
    private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil {
                cachedEnabled = true
            } else {
                cachedEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
            }
        }
    }

    static var isEnabled: Bool {
        _ = observer
        return cachedEnabled
    }

    static func tap() {
        guard isEnabled else { return }
        generator.impactOccurred(intensity: 0.65)
    }
}

struct PlayerFloatingPill: View {
    let title: String
    let hasController: Bool
    let onPause: () -> Void

    var body: some View {
        Button(action: onPause) {
            HStack(spacing: 7) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if hasController {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.45))
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.28, green: 0.84, blue: 0.50))
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.42), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        }
        .buttonStyle(PhoneTactileButtonStyle(pressedScale: 0.95))
        .accessibilityLabel("暂停与菜单")
    }
}

struct PlayerPauseOverlay<ExtraContent: View>: View {
    let title: String
    let subtitle: String
    let hasController: Bool
    @Binding var showVirtualPad: Bool
    @Binding var padOpacity: Double
    @Binding var hapticsEnabled: Bool
    let isExiting: Bool
    let onResume: () -> Void
    let onExit: () -> Void
    @ViewBuilder let extraContent: () -> ExtraContent

    init(
        title: String,
        subtitle: String = "进度已自动保存",
        hasController: Bool,
        showVirtualPad: Binding<Bool>,
        padOpacity: Binding<Double>,
        hapticsEnabled: Binding<Bool>,
        isExiting: Bool = false,
        onResume: @escaping () -> Void,
        onExit: @escaping () -> Void,
        @ViewBuilder extraContent: @escaping () -> ExtraContent = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.hasController = hasController
        self._showVirtualPad = showVirtualPad
        self._padOpacity = padOpacity
        self._hapticsEnabled = hapticsEnabled
        self.isExiting = isExiting
        self.onResume = onResume
        self.onExit = onExit
        self.extraContent = extraContent
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.64)
                .ignoresSafeArea()
                .onTapGesture {
                    if !isExiting { onResume() }
                }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(hasController ? "\(subtitle) · 已连接实体手柄" : subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        Spacer()
                        Button(action: onResume) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.84))
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.11), in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.75))
                        }
                        .buttonStyle(PhoneTactileButtonStyle(pressedScale: 0.92))
                        .disabled(isExiting)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("显示虚拟按键", isOn: $showVirtualPad)
                            .font(.system(size: 13, weight: .medium))
                            .tint(.white)

                        if showVirtualPad {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("按键透明度")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.70))
                                    Spacer()
                                    Text("\(Int(padOpacity * 100))%")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.84))
                                }
                                Slider(value: $padOpacity, in: 0.25...1.0)
                                    .tint(.white)
                            }
                        }

                        Toggle("按键震动反馈", isOn: $hapticsEnabled)
                            .font(.system(size: 13, weight: .medium))
                            .tint(.white)

                        extraContent()
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.75))

                    VStack(spacing: 9) {
                        Button(action: onResume) {
                            Text("继续游戏")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(white: 0.06))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PhoneTactileButtonStyle())
                        .disabled(isExiting)

                        Button(action: onExit) {
                            Text(isExiting ? "正在保存并退出…" : "保存并退出游戏")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.52, blue: 0.56))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.28), lineWidth: 0.75))
                        }
                        .buttonStyle(PhoneTactileButtonStyle())
                        .disabled(isExiting)
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 360)
            .fixedSize(horizontal: false, vertical: true)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(Color(white: 0.08).opacity(0.76), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.65), radius: 32, y: 14)
            .padding(16)
        }
        .preferredColorScheme(.dark)
    }
}
