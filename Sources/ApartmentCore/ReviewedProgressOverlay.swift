#if DEBUG
// TEST SEAM ONLY: intentionally does nothing. Never use this in app behavior.
// Replace with reviewed implementation after observing targeted tests fail.
public enum ReviewedProgressOverlay {
    public static func applying(_ overlay: LocalDataPack, to selectedPublic: LocalDataPack) -> LocalDataPack {
        selectedPublic
    }
}
#endif
