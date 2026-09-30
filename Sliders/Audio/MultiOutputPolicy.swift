/// Pure membership decisions for the multi-output aggregate, split from
/// MultiOutputController so the count boundaries — the branching that strands
/// or preserves the audio route — are unit-testable without creating real
/// aggregates.
enum MultiOutputPolicy {
    /// Wired clocks hold steadier than Bluetooth; the rest drift-compensate.
    static func clock(among devices: [AudioDevice]) -> AudioDevice? {
        devices.first { !$0.isBluetooth } ?? devices.first
    }

    enum Resolution: Equatable {
        case reapply([AudioDevice])
        case dissolve(to: AudioDevice?)
    }

    /// Multi-output only makes sense with two live members; fewer hands the
    /// route back to the single survivor (or to nothing when none is left).
    static func resolution(survivors: [AudioDevice]) -> Resolution {
        survivors.count > 1 ? .reapply(survivors) : .dissolve(to: survivors.first)
    }

    /// Resolves the old membership order against the latest HAL snapshot.
    /// UIDs are stable across a device republish; object IDs are not. Returning
    /// the fresh objects keeps volume listeners and route-away writes off dead
    /// IDs while preserving the user's member order.
    static func refreshed(members: [AudioDevice], present: [AudioDevice]) -> [AudioDevice] {
        let byUID = Dictionary(present.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        return members.compactMap { byUID[$0.uid] }
    }
}
