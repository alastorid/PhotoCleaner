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
        mainMenu.addItem(applicationMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(windowMenuItem())

        NSApp.mainMenu = mainMenu
        // Standard AppKit behaviour: the system menu bar's Window menu, and the
        // Dock's "Windows" list, both read this.
        NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
    }

    // MARK: - PhotoCleaner

    private static func applicationMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "PhotoCleaner")

        let about = menu.addItem(withTitle: "About PhotoCleaner",
                                 action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                 keyEquivalent: "")
        about.target = nil // NSApplication owns this one.

        menu.addItem(.separator())

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
