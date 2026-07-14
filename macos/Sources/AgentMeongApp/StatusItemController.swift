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
    private var reduceMotion = false
    private var pulseTimer: Timer?
    private var pulseStep = 0
    private var pulseRemaining = 0
    private var activityTimer: Timer?
    private var activityFrame = 0
    private var renderedSignature = ""

    init(state: VisualState, liveCount: Int, sourceLabel: String) {
        self.state = state
        self.liveCount = liveCount
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.length = 30
        configureButton(state: state)
        configureContextMenu(state: state, sourceLabel: sourceLabel)
        updateActivityAnimation()
    }

    func showMeongSpaceForDebugging() {
        showSpace()
    }

    func update(
        state: VisualState,
        liveCount: Int,
        sourceLabel: String,
        reduceMotion: Bool
    ) {
        let shouldPulse = self.liveCount > 0 && liveCount == 0 && state == .completed
        self.state = state
        self.liveCount = liveCount
        self.reduceMotion = reduceMotion
        updateActivityAnimation()
        if shouldPulse, !reduceMotion { startCompletionPulse() }
        renderStatusImage()
        item.button?.toolTip = tooltip
        contextMenu.item(at: 0)?.title = "\(sourceLabel) · \(label(for: state))"
    }

    private func configureButton(state: VisualState) {
        guard let button = item.button else { return }
        renderStatusImage()
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
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
        let signature = "\(state.rawValue):\(countBucket):\(pulseStep):\(activityFrame)"
        guard signature != renderedSignature else { return }
        renderedSignature = signature
        item.button?.image = statusImage(color: color(for: state))
    }

    private func statusImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let pulse = CGFloat(self.pulseStep % 4) / 3
            let activityPhase = CGFloat(self.activityFrame) / 12 * .pi * 2
            let activityPulse = self.state == .active ? (sin(activityPhase) + 1) / 2 : 0
            let bodyOffset = self.state == .active ? sin(activityPhase) : 0
            let accent = color.blended(withFraction: 0.16, of: .white) ?? color
            let baseAura: CGFloat = self.state == .quiet ? 0.30 : 0.38
            let auraAlpha = baseAura
                + CGFloat(self.countBucket) * 0.075
                + pulse * 0.18
                + activityPulse * 0.10
            accent.withAlphaComponent(auraAlpha).setFill()
            NSBezierPath(
                ovalIn: rect.insetBy(dx: 1 - pulse * 0.6, dy: 1 - pulse * 0.6)
            ).fill()
            if self.state == .failed {
                self.drawFailure(color: accent)
            } else if self.state == .attention {
                self.drawAttention(color: accent)
            } else {
                self.drawHead(color: accent, bodyOffset: bodyOffset)
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

    private func drawAttention(color: NSColor) {
        color.withAlphaComponent(0.95).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 14, height: 14))
        ring.lineWidth = 2.5
        ring.stroke()
        NSColor.white.withAlphaComponent(0.82).setFill()
        NSBezierPath(ovalIn: NSRect(x: 8.5, y: 8.5, width: 5, height: 5)).fill()
    }

    private func drawFailure(color: NSColor) {
        color.setFill()
        let diamond = NSBezierPath()
        diamond.move(to: CGPoint(x: 11, y: 3.8))
        diamond.line(to: CGPoint(x: 18.2, y: 11))
        diamond.line(to: CGPoint(x: 11, y: 18.2))
        diamond.line(to: CGPoint(x: 3.8, y: 11))
        diamond.close()
        diamond.fill()
        NSColor.white.withAlphaComponent(0.68).setStroke()
        diamond.lineWidth = 0.8
        diamond.stroke()
    }

    private var countBucket: Int {
        if liveCount >= 4 { return 3 }
        if liveCount >= 2 { return 2 }
        return liveCount == 1 ? 1 : 0
    }

    private var tooltip: String {
        let count = liveCount > 0 ? " · 활동 \(liveCount)개" : ""
        return "agent-meong · \(label(for: state))\(count)"
    }

    private func updateActivityAnimation() {
        let shouldAnimate = state == .active && liveCount > 0 && !reduceMotion
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
