import AppKit

/// The menu bar.
///
/// Not decoration. A regular activation-policy app with no menu has no ⌘Q, no
/// ⌘W and no working clipboard, which is most of the difference between "a web
/// page in a window" and an application. Items that act on the window target
/// `AppDelegate`; everything else is left with a nil target so it travels the
/// responder chain and lands on whatever is focused inside the web view — that
/// is how Cut/Copy/Paste reach the filter fields without this code knowing they
/// exist.
///
/// There is no Help menu on purpose: with no help book, "Help" beeps, and a menu
/// item that beeps is worse than no menu item.
@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(windowMenuItem())

        NSApp.mainMenu = mainMenu
        // Standard AppKit behaviour: the system menu bar's Window menu, and the
        // Dock's "Windows" list, both read this.
        NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
    }

    // MARK: - PhotoCleaner

    private static func applicationMenuItem(target: AppDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "PhotoCleaner")

        let about = menu.addItem(withTitle: "About PhotoCleaner",
                                 action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                 keyEquivalent: "")
        about.target = nil // NSApplication owns this one.

        menu.addItem(.separator())

        // Updates, in the application menu where "Check for Updates…" belongs: it
        // is about the app rather than about the window or a document.
        //
        // Left enabled while a download runs. Greying it out would be tidier, but
        // the title bar arc in the same state swaps its own pointer for an arrow,
        // and having the two affordances answer differently sends someone hunting
        // for whichever one still works. The updater ignores a second press, and
        // it is the one place that can tell.
        let check = menu.addItem(withTitle: "Check for Updates…",
                                 action: #selector(AppDelegate.checkForUpdates(_:)),
                                 keyEquivalent: "u")
        check.target = target
        updateItem = check

        // No initial state here. The checkmark is not this file's to guess: it
        // belongs to `Settings.checkForUpdates`, and `MainMenu.updateItem(for:)`
        // writes the one value the updater will actually act on. Guessing `on`
        // would put a tick next to a user who had deliberately turned the check
        // off, and it would survive until the first updater status arrived —
        // which is not instant, because the Photos permission prompt can sit in
        // front of it.
        let automatic = menu.addItem(withTitle: "Check for Updates Automatically",
                                     action: #selector(AppDelegate.toggleAutomaticUpdateChecks(_:)),
                                     keyEquivalent: "")
        automatic.target = target
        automaticItem = automatic

        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide PhotoCleaner",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others",
                     action: #selector(NSApplication.hideOtherApplications(_:)),
                     keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PhotoCleaner",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        return wrap("PhotoCleaner", menu)
    }

    // MARK: - Update items

    /// The two update items, held so one value can drive both.
    ///
    /// `nonisolated(unsafe)` rather than a lock: `install` and `updateItem(for:)`
    /// are both `@MainActor`, so these are only ever touched from the main thread
    /// and a lock would be ceremony around a guarantee the isolation already gives.
    private nonisolated(unsafe) static var updateItem: NSMenuItem?
    private nonisolated(unsafe) static var automaticItem: NSMenuItem?

    /// Reflect one updater state in the menu.
    ///
    /// The item's *title* carries what will happen, because a fixed "Check for
    /// Updates…" sitting next to a known 1.2.3 is a question the user has to
    /// answer mentally. It never becomes an error message: what happened to the
    /// last attempt belongs in the window and the log, not in a menu that is
    /// re-read every time it opens.
    ///
    /// `.checking` deliberately reads as "Check for Updates…" rather than
    /// "Checking…": the menu is left enabled while the updater works, because the
    /// title bar arc in the same state swaps its own pointer for an arrow, and two
    /// affordances that answer differently send someone hunting for whichever one
    /// still works.
    static func updateItem(for status: Updater.Status) {
        automaticItem?.state = status.automaticChecks ? .on : .off
        guard let item = updateItem else { return }
        switch status.phase {
        case .available:
            item.title = status.offered.map { "Update to \($0.version)…" } ?? "Check for Updates…"
        case .downloading:
            item.title = "Downloading Update…"
        case .installing:
            item.title = "Installing Update…"
        case .restarting:
            item.title = "Restarting…"
        default:
            item.title = "Check for Updates…"
        }
    }

    // MARK: - Edit

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo",
                     action: Selector(("redo:")),
                     keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return wrap("Edit", menu)
    }

    // MARK: - View

    private static func viewMenuItem(target: AppDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "View")
        let reload = menu.addItem(withTitle: "Reload Interface",
                                  action: #selector(AppDelegate.reloadInterface(_:)),
                                  keyEquivalent: "r")
        reload.target = target
        return wrap("View", menu)
    }

    // MARK: - Window

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        return wrap("Window", menu)
    }

    /// Submenu titles are what the system looks a menu up by, and
    /// `NSMenuItem(title:)` does not take one from its submenu, so each wrapper
    /// sets it explicitly.
    private static func wrap(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
