import Foundation
import Combine
import AVFoundation
import ApartmentCore

@MainActor
final class LocalNavigation: ObservableObject {
    @Published private var session = LocalGuidanceSession()
    var route: LocalRoute? { session.route }
    var instruction: String { session.instruction }
    var remaining: Double { session.remaining }
    var active: Bool { session.active }
    @Published var voice = true
    private let speech = AVSpeechSynthesizer()
    private var subscription: AnyCancellable?
    private var timer: AnyCancellable?
    private var lastFix: LocationFix?

    func clearPreview() { stop(); session.clearPreview() }
    func canStart(_ identity: RoutePreviewIdentity) -> Bool { session.canStart(identity) }
    func preview(paths: [PathSegment], identity: RoutePreviewIdentity) throws {
        stop()
        try session.preview(paths: paths, identity: identity)
    }
    func start(location: LocationService, identity: RoutePreviewIdentity) throws {
        try session.start(identity: identity, fix: location.fix, at: .now)
        lastFix = location.fix
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        location.start(navigation: true)
        if let announcement = session.announcement { say(announcement) }
        subscription = location.$fix.receive(on: RunLoop.main).sink { [weak self] fix in self?.lastFix = fix; self?.update() }
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.update() }
    }
    func stop() {
        session.stop(); subscription = nil; timer = nil
        speech.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func update() {
        session.update(fix: lastFix, at: .now)
        if session.status == .paused || session.status == .offRoute { speech.stopSpeaking(at: .immediate) }
        if let announcement = session.announcement { say(announcement) }
    }
    private func say(_ text: String) {
        guard voice, active, let fix = lastFix, fix.usable(at: .now), fix.accuracy <= 15 else { return }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }
}

struct GraphNode: Identifiable, Hashable {
    var id: String; var coordinate: Coordinate
    var label: String { String(id.suffix(14)) }
}
func graphNodes(paths: [PathSegment], mode: TravelMode? = nil) -> [GraphNode] {
    var nodes: [String: Coordinate] = [:]
    for path in paths where mode == nil || (path.confirmed && !path.blocked && (path.mode == .both || path.mode == mode) && !(mode == .drive && path.stairs)) {
        if let start = path.coordinates.first { nodes[path.fromNode] = start }
        if let end = path.coordinates.last { nodes[path.toNode] = end }
    }
    return nodes.map { GraphNode(id: $0.key,coordinate: $0.value) }.sorted { $0.id < $1.id }
}
