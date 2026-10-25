struct SettingsNavigation {
    private(set) var section: SettingsSection = .general
    private var backHistory: [SettingsSection] = []
    private var forwardHistory: [SettingsSection] = []

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    mutating func select(_ section: SettingsSection) {
        guard section != self.section else { return }
        backHistory.append(self.section)
        forwardHistory.removeAll()
        self.section = section
    }

    mutating func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(section)
        section = previous
    }

    mutating func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(section)
        section = next
    }
}
