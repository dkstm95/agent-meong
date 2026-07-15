import AgentMeongCore
import AppKit

@MainActor
protocol StatusItemControllerDelegate: AnyObject {
    func statusItemDidRequestSpace(relativeTo positioningView: NSView)
    func statusItemDidRequestQuit()
}

@MainActor
final class StatusItemController: NSObject {
    weak var delegate: StatusItemControllerDelegate?
    private let item: NSStatusItem
    private let contextMenu = NSMenu()
    private var state: VisualState
    private var liveCount: Int
    private var activeCount: Int
    private var reduceMotion = false
    private var pulseTimer: Timer?
    private var pulseStep = 0
    private var pulseRemaining = 0
    private var hasUnseenCompletion = false
    private var activityTimer: Timer?
    private var activityFrame = 0
    private var renderedSignature = ""

    init(state: VisualState, liveCount: Int, activeCount: Int, sourceLabel: String) {
        self.state = state
        self.liveCount = liveCount
        self.activeCount = activeCount
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.length = 30
        configureButton(state: state)
        configureContextMenu(state: state, sourceLabel: sourceLabel)
        updateActivityAnimation()
    }

    func presentMeongSpace() {
        showSpace()
    }

    func update(
        state: VisualState,
        liveCount: Int,
        activeCount: Int,
        sourceLabel: String,
        reduceMotion: Bool
    ) {
        self.state = state
        self.liveCount = liveCount
        self.activeCount = activeCount
        self.reduceMotion = reduceMotion
        updateActivityAnimation()
        renderStatusImage()
        item.button?.toolTip = tooltip
        updateAccessibility()
        contextMenu.item(at: 0)?.title = "\(sourceLabel) · \(label(for: state))"
    }

    @discardableResult
    func notifyCompletion(reduceMotion: Bool, markUnseen: Bool) -> Bool {
        self.reduceMotion = reduceMotion
        hasUnseenCompletion = hasUnseenCompletion || markUnseen
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseStep = 0
        guard !reduceMotion else {
            renderStatusImage()
            item.button?.toolTip = tooltip
            updateAccessibility()
            return hasUnseenCompletion
        }
        startCompletionPulse()
        renderStatusImage()
        item.button?.toolTip = tooltip
        updateAccessibility()
        return hasUnseenCompletion
    }

    func acknowledgeCompletion() {
        guard hasUnseenCompletion else { return }
        hasUnseenCompletion = false
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseStep = 0
        pulseRemaining = 0
        renderStatusImage()
        item.button?.toolTip = tooltip
        updateAccessibility()
    }

    private func configureButton(state: VisualState) {
        guard let button = item.button else { return }
        renderStatusImage()
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setAccessibilityLabel("agent-meong")
        updateAccessibility()
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureContextMenu(state: VisualState, sourceLabel: String) {
        let title = "\(sourceLabel) · \(label(for: state))"
        let stateItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        contextMenu.addItem(stateItem)
        contextMenu.addItem(.separator())
        contextMenu.addItem(menuItem("멍 보기", action: #selector(showSpace), key: "m"))
        contextMenu.addItem(.separator())
        contextMenu.addItem(menuItem("종료", action: #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func renderStatusImage() {
        let signature = "\(state.rawValue):\(countBucket):\(activeCount):\(hasUnseenCompletion):\(pulseStep):\(activityFrame)"
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        item.button?.image = statusImage()
    }

    private func statusImage() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let pulse = CGFloat(self.pulseStep % 4) / 3
            let activityPhase = CGFloat(self.activityFrame) / 12 * .pi * 2
            let hasActivity = self.activeCount > 0
            let showsCompletionSignal = self.hasUnseenCompletion || self.pulseStep > 0
            let activityPulse = hasActivity ? (sin(activityPhase) + 1) / 2 : 0
            let bodyOffset = hasActivity ? sin(activityPhase) : 0
            let bodyColor = self.color(for: self.state)
            let auraColor = showsCompletionSignal ? self.color(for: .completed) : bodyColor
            let accent = auraColor.blended(withFraction: 0.16, of: .white) ?? auraColor
            let baseAura: CGFloat = self.state == .quiet ? 0.30 : 0.38
            let auraAlpha = baseAura
                + CGFloat(self.countBucket) * 0.075
                + pulse * 0.18
                + activityPulse * 0.10
            accent.withAlphaComponent(auraAlpha).setFill()
            NSBezierPath(
                ovalIn: rect.insetBy(dx: 1 - pulse * 0.6, dy: 1 - pulse * 0.6)
            ).fill()
            self.drawHead(color: bodyColor, bodyOffset: bodyOffset)
            if self.state == .attention {
                self.drawAttention(color: bodyColor, bodyOffset: bodyOffset)
            } else if self.state == .failed {
                self.drawFailure(color: bodyColor, bodyOffset: bodyOffset)
            } else if self.state == .cancelled {
                self.drawCancelled(bodyOffset: bodyOffset)
            }
            if showsCompletionSignal {
                self.drawCompletionSignal(color: self.color(for: .completed), pulse: pulse)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawHead(color: NSColor, bodyOffset: CGFloat) {
        let headRect = NSRect(x: 4.5, y: 4.5 + bodyOffset, width: 13, height: 13)
        color.setFill()
        NSBezierPath(ovalIn: headRect).fill()
        NSColor.white.withAlphaComponent(0.58).setStroke()
        let outline = NSBezierPath(ovalIn: headRect.insetBy(dx: 0.35, dy: 0.35))
        outline.lineWidth = 1
        outline.stroke()
        NSColor.white.withAlphaComponent(0.72).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: 9.1, y: 9.1 + bodyOffset, width: 3.3, height: 3.3)
        ).fill()
    }

    private func drawAttention(color: NSColor, bodyOffset: CGFloat) {
        color.withAlphaComponent(0.95).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 3.5, y: 3.5 + bodyOffset, width: 15, height: 15))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    private func drawFailure(color: NSColor, bodyOffset: CGFloat) {
        color.withAlphaComponent(0.92).setStroke()
        let diamond = NSBezierPath()
        diamond.move(to: CGPoint(x: 11, y: 2.8 + bodyOffset))
        diamond.line(to: CGPoint(x: 19.2, y: 11 + bodyOffset))
        diamond.line(to: CGPoint(x: 11, y: 19.2 + bodyOffset))
        diamond.line(to: CGPoint(x: 2.8, y: 11 + bodyOffset))
        diamond.close()
        diamond.lineWidth = 1.35
        diamond.stroke()
    }

    private func drawCompletionSignal(color: NSColor, pulse: CGFloat) {
        color.withAlphaComponent(0.90).setStroke()
        let inset = 1.6 - pulse * 0.5
        let ring = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: 22 - inset * 2, height: 22 - inset * 2))
        ring.lineWidth = 1.15 + pulse * 0.45
        ring.stroke()
    }

    private func drawCancelled(bodyOffset: CGFloat) {
        NSColor.white.withAlphaComponent(0.72).setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 7.2, y: 11 + bodyOffset))
        line.line(to: CGPoint(x: 14.8, y: 11 + bodyOffset))
        line.lineWidth = 1.4
        line.lineCapStyle = .round
        line.stroke()
    }

    private var countBucket: Int {
        if liveCount >= 4 { return 3 }
        if liveCount >= 2 { return 2 }
        return liveCount == 1 ? 1 : 0
    }

    private var tooltip: String {
        let count = liveCount > 0 ? " · 활동 \(liveCount)개" : ""
        let completion = hasUnseenCompletion ? " · 새 완료" : ""
        return "agent-meong · \(label(for: state))\(count)\(completion)"
    }

    private func updateAccessibility() {
        item.button?.setAccessibilityValue(tooltip)
        item.button?.setAccessibilityHelp("왼쪽 클릭으로 agent 움직임을 엽니다. 오른쪽 클릭으로 메뉴를 엽니다.")
    }

    private func updateActivityAnimation() {
        let shouldAnimate = activeCount > 0 && !reduceMotion
        if shouldAnimate, activityTimer == nil {
            activityTimer = Timer.scheduledTimer(
                timeInterval: 0.20,
                target: self,
                selector: #selector(advanceActivityAnimation),
                userInfo: nil,
                repeats: true
            )
        } else if !shouldAnimate, activityTimer != nil {
            activityTimer?.invalidate()
            activityTimer = nil
            activityFrame = 0
        }
    }

    @objc private func advanceActivityAnimation() {
        activityFrame = (activityFrame + 1) % 12
        renderStatusImage()
    }

    private func startCompletionPulse() {
        pulseTimer?.invalidate()
        pulseStep = 1
        pulseRemaining = 6
        pulseTimer = Timer.scheduledTimer(
            timeInterval: 0.16,
            target: self,
            selector: #selector(advanceCompletionPulse),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func advanceCompletionPulse() {
        pulseRemaining -= 1
        pulseStep = pulseRemaining > 0 ? (pulseStep % 3) + 1 : 0
        renderStatusImage()
        if pulseRemaining == 0 {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }

    private func color(for state: VisualState) -> NSColor {
        switch state {
        case .quiet: NSColor(srgbRed: 0.28, green: 0.72, blue: 0.96, alpha: 1)
        case .active: NSColor(srgbRed: 0.04, green: 0.84, blue: 1.00, alpha: 1)
        case .attention: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.12, alpha: 1)
        case .uncertain: NSColor(srgbRed: 0.58, green: 0.62, blue: 0.78, alpha: 1)
        case .completed: NSColor(srgbRed: 0.70, green: 0.55, blue: 1.00, alpha: 1)
        case .cancelled: NSColor(srgbRed: 0.50, green: 0.55, blue: 0.62, alpha: 1)
        case .failed: NSColor(srgbRed: 0.96, green: 0.24, blue: 0.34, alpha: 1)
        }
    }

    private func label(for state: VisualState) -> String {
        switch state {
        case .quiet: "고요함"
        case .active: "활동 중"
        case .attention: "확인 필요"
        case .uncertain: "상태 불확실"
        case .completed: "완료"
        case .cancelled: "취소됨"
        case .failed: "실패 확인 필요"
        }
    }

    @objc private func handleStatusItemClick() {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            showSpace()
            return
        }

        item.menu = contextMenu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func showSpace() {
        guard let button = item.button else { return }
        delegate?.statusItemDidRequestSpace(relativeTo: button)
    }

    @objc private func quit() {
        delegate?.statusItemDidRequestQuit()
    }
}
