/// Startup account setup must respect a menu-only installation.
enum DisplayEntryPolicy {
    enum Surface { case guide, details, settings, none }
    static func startup(guideRequired: Bool, accountsEmpty: Bool, centralHoverEnabled: Bool) -> Surface {
        if guideRequired { return .guide }
        guard accountsEmpty else { return .none }
        return centralHoverEnabled ? .details : .settings
    }
}
