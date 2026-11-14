import Foundation

// MARK: - Store

/// The live equalizer state plus saved profiles, undo history, and the A/B
/// slot. Every change is persisted and pushed to the engine via `onChange`.
@MainActor
final class EqualizerSettings: ObservableObject {
    @Published var data: EqualizerSettingsData {
        didSet {
            guard data != oldValue else { return }
            saveSoon()
            onChange?(data, soloBandID)
        }
    }

    @Published var customProfiles: [EQProfile] {
        didSet { DefaultsStore.save(customProfiles, key: Self.profilesKey) }
    }

    /// The band being auditioned on its own (a band-pass at its frequency).
    @Published var soloBandID: UUID? {
        didSet { if soloBandID != oldValue { onChange?(data, soloBandID) } }
    }

    @Published var selectedBandID: UUID?

    /// The curve parked in the other A/B slot, and which slot is live.
    @Published private(set) var compareSlot: EqualizerSettingsData?
    @Published private(set) var showingB = false

    @Published private(set) var undoStack: [EqualizerSettingsData] = []
    @Published private(set) var redoStack: [EqualizerSettingsData] = []

    var profiles: [EQProfile] { EQProfile.builtIns + customProfiles }

    var activeProfile: EQProfile? { profiles.first { $0.id == data.activeProfileID } }
    var activeProfileName: String { activeProfile?.name ?? "Custom" }

    var usedSlots: Int { data.bands.reduce(0) { $0 + $1.slotCount } }
    var canAddBand: Bool { usedSlots < eqEngineSlots }

    var onChange: ((EqualizerSettingsData, UUID?) -> Void)?

    private static let dataKey = "com.meimei.player.equalizer.v1"
    private static let profilesKey = "com.meimei.player.equalizer.customProfiles.v1"
    private var saveWork: DispatchWorkItem?

    init() {
        if let raw = UserDefaults.standard.data(forKey: Self.dataKey) {
            data = EqualizerSettingsData.load(from: raw)
        } else {
            data = EqualizerSettingsData()
        }
        customProfiles = DefaultsStore.load([EQProfile].self, key: Self.profilesKey) ?? []
    }

    /// Drags change the curve dozens of times a second; persist once they settle.
    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DefaultsStore.save(self.data, key: Self.dataKey)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Undo

    /// Records the current curve so the next edit can be undone. Call once
    /// at the start of a gesture, not on every step of it.
    func checkpoint() {
        if undoStack.last != data { undoStack.append(data) }
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(data)
        data = previous
        dropStaleSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(data)
        data = next
        dropStaleSelection()
    }

    private func dropStaleSelection() {
        if let id = selectedBandID, !data.bands.contains(where: { $0.id == id }) { selectedBandID = nil }
        if let id = soloBandID, !data.bands.contains(where: { $0.id == id }) { soloBandID = nil }
    }

    // MARK: A/B

    /// Swaps the live curve with the other slot. The first switch to B
    /// starts it as a copy of A.
    func toggleCompare() {
        let parked = compareSlot ?? data
        compareSlot = data
        showingB.toggle()
        var next = parked
        next.enabled = data.enabled
        data = next
        dropStaleSelection()
    }

    /// Copies the live slot over the other one.
    func copyToOtherSlot() {
        compareSlot = data
    }

    // MARK: Edits

    func setEnabled(_ on: Bool) { edit(checkpoint: false, keepProfile: true) { $0.enabled = on } }

    func applyProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        edit { d in
            d.bands = profile.bands.map { var b = $0; b.id = UUID(); return b }
            d.preampGain = profile.preampGain
        }
        data.activeProfileID = id
        selectedBandID = nil
        soloBandID = nil
    }

    func updateBand(_ id: UUID, checkpoint: Bool = false, _ body: (inout EQBand) -> Void) {
        guard let i = data.bands.firstIndex(where: { $0.id == id }) else { return }
        edit(checkpoint: checkpoint) { d in
            body(&d.bands[i])
            d.bands[i] = d.bands[i].clamped(gainLimit: d.gainRange.rawValue)
        }
    }

    /// Adds a band, picking a type that suits where it lands: cuts at the
    /// extremes, bells elsewhere. Returns its id.
    @discardableResult
    func addBand(frequency: Double, gain: Double = 0, type: EQFilterType? = nil) -> UUID? {
        guard canAddBand else { return nil }
        let kind = type ?? (frequency < 30 ? .lowCut : frequency > 16_000 ? .highCut : .bell)
        let band = EQBand(type: kind, frequency: frequency, gain: kind.hasGain ? gain : 0, q: kind == .notch ? 4 : 0.71)
            .clamped(gainLimit: data.gainRange.rawValue)
        edit { $0.bands.append(band) }
        selectedBandID = band.id
        return band.id
    }

    func removeBand(_ id: UUID) {
        edit { $0.bands.removeAll { $0.id == id } }
        dropStaleSelection()
    }

    func duplicateBand(_ id: UUID) {
        guard canAddBand, let band = data.bands.first(where: { $0.id == id }) else { return }
        var copy = band
        copy.id = UUID()
        copy.frequency = min(EQBand.frequencyRange.upperBound, band.frequency * 1.5)
        edit { $0.bands.append(copy) }
        selectedBandID = copy.id
    }

    func setPreamp(_ value: Double, checkpoint: Bool = false) {
        edit(checkpoint: checkpoint, keepProfile: true) { d in
            d.preampGain = min(24, max(-30, value))
            d.autoPreamp = false
        }
    }

    func setGainRange(_ range: EQGainRange) {
        edit(keepProfile: true) { d in
            d.gainRange = range
            d.bands = d.bands.map { $0.clamped(gainLimit: range.rawValue) }
        }
    }

    func setAutoPreamp(_ on: Bool) { edit(keepProfile: true) { $0.autoPreamp = on } }

    func setShowAnalyzer(_ on: Bool) { data.showAnalyzer = on }

    /// Scales every band's gain (−100%…+200%), as a DAW's "depth" control does.
    func scaleGains(by factor: Double) {
        edit { d in
            d.bands = d.bands.map { var b = $0; b.gain *= factor; return b.clamped(gainLimit: d.gainRange.rawValue) }
        }
    }

    func invertGains() { scaleGains(by: -1) }

    func resetFlat() {
        edit { d in
            d.bands = []
            d.preampGain = 0
        }
        data.activeProfileID = EQProfile.flatID
        selectedBandID = nil
        soloBandID = nil
    }

    /// Applies a batch of changes as one update and recomputes the
    /// automatic preamp when it's on. Curve edits detach from the profile.
    private func edit(checkpoint record: Bool = true, keepProfile: Bool = false, _ body: (inout EqualizerSettingsData) -> Void) {
        if record { checkpoint() }
        var d = data
        body(&d)
        if !keepProfile, d.bands != data.bands || d.preampGain != data.preampGain { d.activeProfileID = nil }
        if d.autoPreamp { d.preampGain = Self.autoPreamp(for: d) }
        data = d
    }

    // MARK: Profiles

    @discardableResult
    func saveCurrentAsNewProfile(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = EQProfile(name: trimmed.isEmpty ? "Custom" : trimmed, bands: data.bands, preampGain: data.preampGain)
        customProfiles.append(profile)
        data.activeProfileID = profile.id
        return profile.id
    }

    func overwriteProfile(_ id: UUID) {
        guard let i = customProfiles.firstIndex(where: { $0.id == id }) else { return }
        customProfiles[i].bands = data.bands
        customProfiles[i].preampGain = data.preampGain
        data.activeProfileID = id
    }

    func renameProfile(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = customProfiles.firstIndex(where: { $0.id == id }) else { return }
        customProfiles[i].name = trimmed
    }

    func deleteProfile(_ id: UUID) {
        customProfiles.removeAll { $0.id == id }
        if data.activeProfileID == id { data.activeProfileID = nil }
    }

    /// Adds a profile read from a file and applies it.
    func importProfile(_ profile: EQProfile) {
        var p = profile
        p.id = UUID()
        p.isBuiltIn = false
        customProfiles.append(p)
        applyProfile(p.id)
    }

    /// Makeup gain that cancels the curve's highest point. Overlapping
    /// bands can boost more than any single band shows, so this measures
    /// the summed response.
    static func autoPreamp(for data: EqualizerSettingsData) -> Double {
        var flat = data
        flat.preampGain = 0
        var peak = 0.0
        for i in 0...160 {
            let hz = 20 * pow(1000, Double(i) / 160)
            peak = max(peak, EqualizerResponse.gain(atHz: hz, data: flat))
        }
        return min(0, -((peak * 10).rounded(.up) / 10))
    }
}

