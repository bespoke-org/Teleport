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

    mutating func selectNextSidebarSection() {
        selectSidebarSection(offset: 1)
    }

    mutating func selectPreviousSidebarSection() {
        selectSidebarSection(offset: -1)
    }

    private mutating func selectSidebarSection(offset: Int) {
        let sections = SettingsSection.sidebarSections
        guard let index = sections.firstIndex(of: section.sidebarSection) else { return }
        select(sections[(index + offset + sections.count) % sections.count])
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
