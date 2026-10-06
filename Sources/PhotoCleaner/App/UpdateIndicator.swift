import AppKit
import Foundation

/// The update indicator: a download glyph in the title bar that *is* the update
/// control.
///
/// Beside the title rather than in a menu, because the thing it does is not a
/// preference — it is "replace the running app". A menu item for that is three
/// clicks deep and shows no status; a control in the title bar is visible
/// whenever an update exists, reports its own progress, and is one click.
///
/// Three states, drawn rather than assembled from three images:
///
///   * nothing to report — a plain grey glyph over a faint ring.
///   * an update is waiting — the same glyph in the accent colour.
///   * work in progress — the glyph back in grey, with a blue arc around it
///     sweeping from 0 to 2π as the download advances, over the faint ring.
///
/// The arc is the load-bearing part. A spinner says "something is happening" and
/// a determinate bar says "how much"; an arc that is *both* is what tells
/// someone watching a 15 MB download over hotel wifi that it is still moving.
/// The grey-under-blue is deliberate: the glyph never competes with the ring for
/// attention, and the ring is the only thing that changes shape.
///
/// Drawn with Core Graphics rather than composed from `NSImage`s because the arc
/// has to sweep to an arbitrary angle. There is no template image for "60% of a
/// ring", and approximating it with pre-rendered wedges would quantise the one
/// thing the control exists to communicate.
@MainActor
final class UpdateIndicatorView: NSView {
    /// Drawn from this, and nothing else.
    private var status = Updater.Status()

    /// The control's side. Toolbar-glyph sized, so it does not read as a large
    /// button where none is.
    static let side: CGFloat = 18

    /// Space left around the ring, so a complete arc never touches the title.
    private static let outerInset: CGFloat = 1.5

    /// Stroke width for both the track and the arc. The arc is drawn at the same
    /// weight as the track on purpose: a thicker arc would read as a different,
    /// more important ring rather than as the track filling up.
    private static let ringLineWidth: CGFloat = 1.75

    /// Clicked. Set by the window; ignored while the updater is busy, which is
    /// what stops a second flow starting over the first.
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Transparent: the title bar's own material shows through, so the control
        // is legible over both light and dark title bars without a background to
        // keep in step with the appearance.
        wantsLayer = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("UpdateIndicatorView is created in code, not from a nib")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// The one piece of state. Everything drawn is derived from it, so the ring
    /// and the glyph cannot disagree about the phase.
    func apply(_ status: Updater.Status) {
        guard status != self.status else { return }
        self.status = status
        updateAccessibility()
        needsDisplay = true
        // A control whose meaning changed should also say so: a stale pointer
        // rect is how a live button keeps an arrow cursor.
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Drawing

    /// Not flipped, and every coordinate below assumes that: `minY` is the bottom
    /// and an arc drawn from 90° clockwise sweeps from twelve o'clock the way every
    /// progress indicator the user has met does. Flipping the view would mirror
    /// both the glyph and the direction of the sweep.
    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.outerInset + Self.ringLineWidth
        let side = Self.side - inset * 2
        // Square the ring's box: `bounds` is the control's, and a half-point
        // difference between its width and height turns the track into an ellipse.
        let originX = bounds.midX - side / 2
        let ring = NSRect(x: originX, y: bounds.midY - side / 2, width: side, height: side)

        drawTrack(in: ring)
        if let fraction = status.phase.fraction {
            drawArc(in: ring, fraction: fraction)
        } else if status.phase.isBusy {
            // Busy with no fraction: installing, or a download whose total length
            // was not in the response headers. A full ring says "working" without
            // claiming to know how far along it is.
            drawArc(in: ring, fraction: 1)
        }

        drawGlyph(in: ring)
    }

    /// The faint full circle the progress arc is drawn over.
    ///
    /// Present in every state, not only while downloading. A ring that first
    /// appeared alongside the arc would make the first percent of progress read as
    /// the control changing rather than as a movement starting.
    private func drawTrack(in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = Self.ringLineWidth
        // Tertiary label: legible in both title bar appearances and quiet enough
        // that a filled arc over it reads as the change.
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    /// The blue arc, from 0 to `fraction × 2π`, clockwise from twelve o'clock.
    private func drawArc(in rect: NSRect, fraction: Double) {
        // Clamped just below 1: a 2-point sweep is not a circle, and a full turn
        // would overlap its own ends. At 1.0 the ring reads as filled, which is the
        // honest depiction of "complete" without two strokes fighting over the
        // same pixels.
        let sweep = min(max(fraction, 0), 0.9999)
        guard sweep > 0 else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                       radius: rect.width / 2,
                       startAngle: 90,
                       endAngle: 90 - 360 * sweep,
                       clockwise: true)
        path.lineWidth = Self.ringLineWidth
        path.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// The download glyph: a downward arrow into a tray.
    ///
    /// The same glyph in every state — a different icon for "ready" would imply a
    /// different *action*, and the action is the same. Only the colour changes:
    /// accent when an update is waiting, red when the last attempt failed, grey
    /// otherwise and always while work is in progress, so the arc stays the only
    /// thing moving.
    private func drawGlyph(in ring: NSRect) {
        let colour: NSColor = switch status.phase {
        case .available: .controlAccentColor
        case .failed: .systemRed
        default: .secondaryLabelColor
        }
        colour.setStroke()

        // The glyph is sized from the ring, not the control: the ring's radius is
        // what the eye reads as "the circle", and a download arrow sized off the
        // view instead leaves a noticeably wider margin on the diagonals. 0.62 of
        // the diameter puts the arrow's corners just inside the ring's stroke.
        let side = ring.width * 0.62
        let box = NSRect(x: ring.midX - side / 2, y: ring.midY - side / 2, width: side, height: side)
        let lineWidth = max(1.2, side * 0.11)

        // The tray: a "U", open at the top, because the arrow comes down into it.
        // Its arms stop a third of the way up rather than halfway — a tray that
        // reaches too high reads as a box, which is the wrong symbol entirely.
        let trayBottom = box.minY + box.height * 0.08
        let trayArm = box.height * 0.26
        let half = box.width * 0.34
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: box.midX - half, y: trayBottom + trayArm))
        tray.line(to: NSPoint(x: box.midX - half, y: trayBottom))
        tray.line(to: NSPoint(x: box.midX + half, y: trayBottom))
        tray.line(to: NSPoint(x: box.midX + half, y: trayBottom + trayArm))
        tray.lineWidth = lineWidth
        tray.lineCapStyle = .round
        tray.lineJoinStyle = .round
        tray.stroke()

        // The arrow: a shaft and a chevron, both on the centre line. The head ends
        // a clear gap above the tray — close enough to read as pointing into it,
        // far enough that the two strokes never merge at 18pt.
        let shaftTop = box.maxY - box.height * 0.1
        let headApex = box.maxY - box.height * 0.46
        let shoulder = box.height * 0.2
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: box.midX, y: shaftTop))
        arrow.line(to: NSPoint(x: box.midX, y: headApex))
        arrow.move(to: NSPoint(x: box.midX - box.width * 0.22, y: headApex + shoulder))
        arrow.line(to: NSPoint(x: box.midX, y: headApex))
        arrow.line(to: NSPoint(x: box.midX + box.width * 0.22, y: headApex + shoulder))
        arrow.lineWidth = lineWidth
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        // A click on a control that cannot act is invisible to the user, so busy
        // phases are handled by the cursor instead: no arrow hand, no click, and
        // the tooltip says what is happening.
        guard let onClick, status.phase.isActionable else { return }
        onClick()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: status.phase.isActionable ? .pointingHand : .arrow)
    }

    // MARK: - Accessibility

    /// VoiceOver can see none of the above, and the drawing is all of it. The
    /// label carries the state, the value the progress, the help the consequence.
    private func updateAccessibility() {
        switch status.phase {
        case .idle:
            setAccessibilityLabel("Check for PhotoCleaner updates")
            setAccessibilityValue(nil)
        case .checking:
            setAccessibilityLabel("Checking for PhotoCleaner updates")
            setAccessibilityValue(nil)
        case .upToDate:
            setAccessibilityLabel("PhotoCleaner is up to date")
            setAccessibilityValue(status.installedVersion.map { "version \($0)" })
        case .available:
            setAccessibilityLabel("Download and install the PhotoCleaner update")
            setAccessibilityValue(status.offered.map { "version \($0.version)" })
        case .downloading(let received, let expected):
            setAccessibilityLabel("Downloading the PhotoCleaner update")
            if let expected, expected > 0 {
                let percent = Int((Double(received) / Double(expected) * 100).rounded())
                setAccessibilityValue("\(percent) percent")
            } else {
                // The length was not in the headers. "Downloading" and nothing
                // more: a number invented here would be read out as fact.
                setAccessibilityValue("downloading")
            }
        case .installing:
            setAccessibilityLabel("Installing the PhotoCleaner update")
            setAccessibilityValue(nil)
        case .restarting:
            setAccessibilityLabel("Restarting PhotoCleaner")
            setAccessibilityValue(nil)
        case .failed(let message):
            setAccessibilityLabel("The PhotoCleaner update failed")
            setAccessibilityValue(message)
        }
        setAccessibilityHelp(Self.tooltip(for: status))
    }

    /// The one-line explanation on hover, and the sentence the tests check.
    ///
    /// Also the only place the *consequence* is stated in words: the arc is
    /// unambiguous about progress and entirely silent about what progress is for.
    ///
    /// `nonisolated` because it is a pure function of its argument, and the
    /// regression suite calls it from off the main actor — the same reasoning as
    /// `AppWindow.isOwnServer`.
    nonisolated static func tooltip(for status: Updater.Status) -> String {
        let running = status.installedVersion.map { "PhotoCleaner \($0)" } ?? "This version of PhotoCleaner"
        switch status.phase {
        case .idle:
            return "Click to check for a new version of PhotoCleaner."
        case .checking:
            return "Checking for a new version…"
        case .upToDate:
            return "\(running) is the newest published release."
        case .available:
            guard let offer = status.offered else { return "A new version is available." }
            return "PhotoCleaner \(offer.version) is available.\nClick to download it, install it and restart."
        case .downloading(let received, let expected):
            guard let expected, expected > 0 else { return "Downloading PhotoCleaner…" }
            let percent = Int((Double(received) / Double(expected) * 100).rounded())
            return "Downloading PhotoCleaner… \(percent)%"
        case .installing:
            return "Installing the update…"
        case .restarting:
            return "Restarting…"
        case .failed(let message):
            return "\(message)\nClick to try again."
        }
    }
}

/// Hosts `UpdateIndicatorView` as a title bar accessory.
///
/// A controller because that is what puts a view in the title bar, and because
/// `NSTitlebarAccessoryViewController` keeps it there across a resize and a
/// full-screen transition — both of which happen while an update is downloading,
/// which is exactly when losing the control would be worst.
@MainActor
final class UpdateIndicatorController: NSTitlebarAccessoryViewController {
    /// Posted when the arc is clicked.
    ///
    /// A notification rather than a stored closure: the click has to travel from a
    /// view inside AppKit's title bar up to `AppDelegate`, which is the only
    /// object that holds the `Updater`. `nonisolated` because the delegate will
    /// read it, and a `@MainActor` type's static would otherwise be isolated too.
    nonisolated static let clicked = Notification.Name("PhotoCleanerUpdateIndicatorClicked")

    private var indicator = UpdateIndicatorView(
        frame: NSRect(x: 0, y: 0, width: UpdateIndicatorView.side, height: UpdateIndicatorView.side))

    override func loadView() {
        view = indicator
        // `.top` puts it on the title line beside the title, not on the toolbar
        // row beneath it.
        layoutAttribute = .top
        // The height of the title bar itself, so an 18pt control is centred on the
        // title's line rather than against the accessory's own row.
        fullScreenMinHeight = 28
        indicator.onClick = {
            NotificationCenter.default.post(name: UpdateIndicatorController.clicked, object: nil)
        }
    }

    func apply(_ status: Updater.Status) {
        indicator.apply(status)
        indicator.toolTip = UpdateIndicatorView.tooltip(for: status)
    }
}
