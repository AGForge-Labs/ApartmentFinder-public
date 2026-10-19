import SwiftUI

@main
struct ApartmentFinderApp: App {
    @StateObject private var store: AppStore
    #if DEBUG
    private let preferences: UserDefaults
    #endif
    init() {
        #if DEBUG
        preferences = UITestSupport.preferences()
        UITestSupport.resetInboxIfRequested()
        _store = StateObject(wrappedValue: AppStore(storeURL: UITestSupport.storeURL(), loadPublicCatalog: UITestSupport.loadPublicCatalog))
        #else
        _store = StateObject(wrappedValue: AppStore())
        #endif
    }
    @StateObject private var location = LocationService()
    var body: some Scene {
        WindowGroup {
            RootView(store: store, location: location)
                .tint(.teal)
                .preferredColorScheme(.dark)
        }
        #if DEBUG
        .defaultAppStorage(preferences)
        #endif
    }
}
