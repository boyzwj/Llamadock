import Observation

@MainActor
@Observable
final class AppModel {
    var selectedSection: AppSection? = .overview
}
