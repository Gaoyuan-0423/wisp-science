import Foundation
import WispProjectBrowser

/// Keep search/filter selection consistent with the currently visible project cards.
struct ProjectBrowserPresentation {
    var search = ""
    var starredOnly = false
    var selectedID: String?

    func visibleProjects(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { project in
            (!starredOnly || project.starred) && (query.isEmpty
                || project.name.localizedCaseInsensitiveContains(query)
                || project.description.localizedCaseInsensitiveContains(query)
                || project.workspaceDirectory.localizedCaseInsensitiveContains(query))
        }
    }

    mutating func reconcile(_ projects: [ProjectSummary]) {
        let visible = visibleProjects(projects)
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
    }
}
