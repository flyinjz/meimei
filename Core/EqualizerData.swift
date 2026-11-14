import Foundation

// MARK: - Bands

/// What one EQ band does to the signal.
enum EQFilterType: String, Codable, CaseIterable, Identifiable {
    case bell, lowShelf, highShelf, lowCut, highCut, notch, bandPass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bell: return "Bell"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowCut: return "Low Cut"
        case .highCut: return "High Cut"
        case .notch: return "Notch"
        case .bandPass: return "Band Pass"
        }
    }

    var symbol: String {
        switch self {
        case .bell: return "chevron.up"
        case .lowShelf: return "arrow.down.left"
        case .highShelf: return "arrow.up.right"
        case .lowCut: return "arrow.up.forward"
        case .highCut: return "arrow.down.forward"
        case .notch: return "chevron.down"
        case .bandPass: return "dot.radiowaves.up.forward"
        }
    }

    var hasGain: Bool { self == .bell || self == .lowShelf || self == .highShelf }
    var hasQ: Bool { self == .bell || self == .notch || self == .bandPass }
    var hasSlope: Bool { self == .lowCut || self == .highCut }
}

/// One band of the parametric EQ.
struct EQBand: Codable, Equatable, Identifiable {
    var id = UUID()
    var type: EQFilterType = .bell
    /// Center or corner frequency, in Hz.
    var frequency: Double
    var gain: Double = 0
    var q: Double = 0.71
    /// Roll-off of the cut filters, in dB/octave (a multiple of 12).
    var slope: Int = 12
    var enabled = true

    static let frequencyRange: ClosedRange<Double> = 20...20_000
    static let qRange: ClosedRange<Double> = 0.1...18
    static let slopes = [12, 24, 36, 48]

    init(type: EQFilterType = .bell, frequency: Double, gain: Double = 0, q: Double = 0.71, slope: Int = 12, enabled: Bool = true) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.slope = slope
        self.enabled = enabled
    }

    /// Bandwidth in octaves, the unit `AVAudioUnitEQ` takes.
    var octaves: Double { 2 * asinh(1 / (2 * q)) / log(2) }

    static func q(fromOctaves bw: Double) -> Double {
        1 / (2 * sinh(log(2) / 2 * bw))
    }

    /// Engine slots this band needs: cuts cascade one 12 dB/oct filter per step.
    var slotCount: Int { type.hasSlope ? max(1, slope / 12) : 1 }

    func clamped(gainLimit: Double) -> EQBand {
        var b = self
        b.frequency = min(Self.frequencyRange.upperBound, max(Self.frequencyRange.lowerBound, frequency))
        b.gain = min(gainLimit, max(-gainLimit, gain))
        b.q = min(Self.qRange.upperBound, max(Self.qRange.lowerBound, q))
        b.slope = Self.slopes.min { abs($0 - slope) < abs($1 - slope) } ?? 12
        return b
    }
}

/// Vertical scale of the EQ editor; also the gain limit.
enum EQGainRange: Double, CaseIterable, Codable, Identifiable {
    case six = 6, twelve = 12, eighteen = 18, twentyFour = 24, thirty = 30

    var id: Double { rawValue }
    var label: String { "±\(Int(rawValue)) dB" }
    var closed: ClosedRange<Double> { -rawValue...rawValue }
}

// MARK: - Profiles

/// A named EQ curve: a built-in starting point (read-only) or one the user saved.
struct EQProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var bands: [EQBand]
    var preampGain: Double
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, bands: [EQBand], preampGain: Double = 0, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.bands = bands
        self.preampGain = preampGain
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bands, preampGain, isBuiltIn, bandGains, bandBypass, bandwidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        preampGain = try c.decodeIfPresent(Double.self, forKey: .preampGain) ?? 0
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        if let bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) {
            self.bands = bands
        } else {
            // Profiles saved by the 10-band graphic EQ.
            self.bands = EQProfile.graphic(
                gains: try c.decodeIfPresent([Double].self, forKey: .bandGains) ?? [],
                bypass: try c.decodeIfPresent([Bool].self, forKey: .bandBypass) ?? [],
                octaves: try c.decodeIfPresent(Double.self, forKey: .bandwidth) ?? 1
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(bands, forKey: .bands)
        try c.encode(preampGain, forKey: .preampGain)
        try c.encode(isBuiltIn, forKey: .isBuiltIn)
    }

    /// Center frequencies of the classic ten-band graphic EQ.
    static let graphicFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Ten bells at the graphic-EQ frequencies.
    static func graphic(gains: [Double], bypass: [Bool] = [], octaves: Double = 1) -> [EQBand] {
        graphicFrequencies.enumerated().map { i, f in
            EQBand(frequency: f, gain: gains.indices.contains(i) ? gains[i] : 0, q: EQBand.q(fromOctaves: octaves),
                   enabled: !(bypass.indices.contains(i) && bypass[i]))
        }
    }
}

extension EQProfile {
    static let flatID = UUID(uuidString: "9E5B0000-0000-4000-8000-000000000001")!

    private static func builtIn(_ n: Int, _ name: String, preamp: Double = 0, _ bands: [EQBand]) -> EQProfile {
        EQProfile(id: UUID(uuidString: String(format: "9E5B0000-0000-4000-8000-%012d", n))!,
                  name: name, bands: bands, preampGain: preamp, isBuiltIn: true)
    }

    static let builtIns: [EQProfile] = [
        builtIn(1, "Flat", []),
        builtIn(2, "Bass Boost", preamp: -5, [
            EQBand(type: .lowShelf, frequency: 105, gain: 6),
            EQBand(frequency: 60, gain: 1.5, q: 1),
        ]),
        builtIn(3, "Treble Boost", preamp: -5, [EQBand(type: .highShelf, frequency: 4500, gain: 5.5)]),
        builtIn(4, "Vocal", preamp: -3, [
            EQBand(type: .lowCut, frequency: 90, slope: 12),
            EQBand(frequency: 250, gain: -2, q: 1.2),
            EQBand(frequency: 2800, gain: 3, q: 0.9),
            EQBand(type: .highShelf, frequency: 9000, gain: -1.5),
        ]),
        builtIn(5, "Rock", preamp: -4, [
            EQBand(type: .lowShelf, frequency: 90, gain: 4),
            EQBand(frequency: 700, gain: -2, q: 0.8),
            EQBand(type: .highShelf, frequency: 5000, gain: 3.5),
        ]),
        builtIn(6, "Pop", preamp: -3, [
            EQBand(frequency: 120, gain: 2, q: 0.9),
            EQBand(frequency: 400, gain: 2.5, q: 0.8),
            EQBand(type: .highShelf, frequency: 8000, gain: -1),
        ]),
        builtIn(7, "Classical", preamp: -3, [
            EQBand(type: .lowShelf, frequency: 120, gain: 2.5),
            EQBand(type: .highShelf, frequency: 6000, gain: 2.5),
        ]),
        builtIn(8, "Electronic", preamp: -5, [
            EQBand(type: .lowShelf, frequency: 80, gain: 5),
            EQBand(frequency: 500, gain: -1.5, q: 0.9),
            EQBand(type: .highShelf, frequency: 7000, gain: 4),
        ]),
        builtIn(9, "Loudness", preamp: -5, [
            EQBand(type: .lowShelf, frequency: 100, gain: 5),
            EQBand(frequency: 3000, gain: -1, q: 0.7),
            EQBand(type: .highShelf, frequency: 10000, gain: 4),
        ]),
        builtIn(10, "Hip-Hop", preamp: -6, [
            EQBand(frequency: 55, gain: 6, q: 0.9),
            EQBand(frequency: 300, gain: -2, q: 1),
            EQBand(frequency: 3500, gain: 1.5, q: 1),
        ]),
        builtIn(11, "Acoustic", preamp: -2, [
            EQBand(frequency: 200, gain: 1.5, q: 0.8),
            EQBand(frequency: 2500, gain: 2, q: 0.9),
            EQBand(type: .highShelf, frequency: 9000, gain: 1.5),
        ]),
        builtIn(12, "Spoken Word", preamp: -3, [
            EQBand(type: .lowCut, frequency: 100, slope: 24),
            EQBand(frequency: 3000, gain: 3, q: 0.8),
            EQBand(type: .highCut, frequency: 12000, slope: 12),
        ]),
        builtIn(13, "Late Night", preamp: -1, [
            EQBand(type: .lowShelf, frequency: 120, gain: -4),
            EQBand(frequency: 2500, gain: 1.5, q: 0.8),
            EQBand(type: .highShelf, frequency: 7000, gain: -3),
        ]),
        builtIn(14, "Warm", preamp: -2, [
            EQBand(type: .lowShelf, frequency: 200, gain: 2),
            EQBand(type: .highShelf, frequency: 6000, gain: -2.5),
        ]),
        builtIn(15, "Bright", preamp: -3, [
            EQBand(frequency: 300, gain: -1.5, q: 0.7),
            EQBand(type: .highShelf, frequency: 3500, gain: 3),
        ]),
    ]
}

// MARK: - Live state

/// The live equalizer state, persisted as one blob.
struct EqualizerSettingsData: LenientDecodable, Equatable {
    var enabled = false
    /// Gain applied before the filters (headroom for boosts).
    var preampGain: Double = 0
    var bands: [EQBand] = []
    var autoPreamp = false
    var gainRange: EQGainRange = .twelve
    var activeProfileID: UUID? = EQProfile.flatID
    var showAnalyzer = true

    init() {}

    /// Older builds stored a fixed ten-band graphic EQ.
    private struct Legacy: Decodable {
        var bandGains: [Double]
        var bandBypass: [Bool]?
        var bandwidth: Double?
    }

    static func load(from data: Data) -> Self {
        var d = decodeLeniently(from: data)
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw["bands"] == nil,
           let legacy = try? JSONDecoder().decode(Legacy.self, from: data) {
            d.bands = EQProfile.graphic(gains: legacy.bandGains, bypass: legacy.bandBypass ?? [], octaves: legacy.bandwidth ?? 1)
                .filter { abs($0.gain) > 0.001 }
        }
        return d
    }
}

/// Engine slots available to bands (cut filters take one per 12 dB/oct).
let eqEngineSlots = 48

/// Magnitude response of the EQ: RBJ biquads matching the filters the
/// engine runs, evaluated at 48 kHz.
enum EqualizerResponse {
    static let sampleRate = 48_000.0

    static func gain(atHz hz: Double, data: EqualizerSettingsData) -> Double {
        data.bands.reduce(data.preampGain) { $0 + (($1.enabled) ? gain(atHz: hz, band: $1) : 0) }
    }

    static func gain(atHz hz: Double, band: EQBand) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let f0 = min(band.frequency, sampleRate * 0.49)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let a = pow(10, band.gain / 40)
        var c: (Double, Double, Double, Double, Double, Double)
        var repeats = 1.0
        switch band.type {
        case .bell:
            guard abs(band.gain) > 0.001 else { return 0 }
            let alpha = sw / (2 * band.q)
            c = (1 + alpha * a, -2 * cw, 1 - alpha * a, 1 + alpha / a, -2 * cw, 1 - alpha / a)
        case .lowShelf, .highShelf:
            guard abs(band.gain) > 0.001 else { return 0 }
            let alpha = sw / 2 * 2.0.squareRoot()
            let s = 2 * a.squareRoot() * alpha
            if band.type == .lowShelf {
                c = (a * ((a + 1) - (a - 1) * cw + s), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - s),
                     (a + 1) + (a - 1) * cw + s, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - s)
            } else {
                c = (a * ((a + 1) + (a - 1) * cw + s), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - s),
                     (a + 1) - (a - 1) * cw + s, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - s)
            }
        case .lowCut, .highCut:
            let alpha = sw / (2 * 0.5.squareRoot())
            repeats = Double(band.slotCount)
            if band.type == .lowCut {
                c = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
            } else {
                c = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha)
            }
        case .notch:
            let alpha = sw / (2 * band.q)
            c = (1, -2 * cw, 1, 1 + alpha, -2 * cw, 1 - alpha)
        case .bandPass:
            let alpha = sw / (2 * band.q)
            c = (alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha)
        }
        let db = 20 * log10(magnitude(c.0, c.1, c.2, w) / magnitude(c.3, c.4, c.5, w))
        return max(-120, db * repeats)
    }

    private static func magnitude(_ c0: Double, _ c1: Double, _ c2: Double, _ w: Double) -> Double {
        let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
        let im = -(c1 * sin(w) + c2 * sin(2 * w))
        return max(1e-12, (re * re + im * im).squareRoot())
    }
}

// MARK: - Interchange

/// Reads and writes Equalizer APO / AutoEQ "ParametricEQ.txt" files, the
/// format headphone correction presets are published in.
enum ParametricEQText {
    static func parse(_ text: String, name: String) -> EQProfile? {
        var bands: [EQBand] = []
        var preamp = 0.0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("preamp:") {
                preamp = number(after: "preamp:", in: lower) ?? 0
                continue
            }
            guard lower.hasPrefix("filter"), lower.contains(" on ") || lower.contains(":on ") else { continue }
            let tokens = line.replacingOccurrences(of: ":", with: " ").split(separator: " ").map(String.init)
            guard let onIndex = tokens.firstIndex(where: { $0.uppercased() == "ON" }), onIndex + 1 < tokens.count else { continue }
            let kind: EQFilterType?
            switch tokens[onIndex + 1].uppercased() {
            case "PK", "PEQ", "MODAL": kind = .bell
            case "LS", "LSC", "LSQ", "LS6", "LS12": kind = .lowShelf
            case "HS", "HSC", "HSQ", "HS6", "HS12": kind = .highShelf
            case "HP", "HPQ": kind = .lowCut
            case "LP", "LPQ": kind = .highCut
            case "NO": kind = .notch
            case "BP": kind = .bandPass
            default: kind = nil
            }
            guard let kind, let fc = value(after: "Fc", in: tokens) else { continue }
            var band = EQBand(type: kind, frequency: fc, gain: value(after: "Gain", in: tokens) ?? 0)
            if let q = value(after: "Q", in: tokens) { band.q = q }
            else if let bw = value(after: "BW", in: tokens) { band.q = EQBand.q(fromOctaves: bw) }
            bands.append(band.clamped(gainLimit: 30))
        }
        guard !bands.isEmpty else { return nil }
        return EQProfile(name: name, bands: bands, preampGain: preamp)
    }

    static func export(_ data: EqualizerSettingsData) -> String {
        var lines = [String(format: "Preamp: %.1f dB", data.preampGain)]
        for (i, b) in data.bands.enumerated() {
            let code: String
            switch b.type {
            case .bell: code = "PK"
            case .lowShelf: code = "LSC"
            case .highShelf: code = "HSC"
            case .lowCut: code = "HP"
            case .highCut: code = "LP"
            case .notch: code = "NO"
            case .bandPass: code = "BP"
            }
            var line = String(format: "Filter %d: %@ %@ Fc %.0f Hz", i + 1, b.enabled ? "ON" : "OFF", code, b.frequency)
            if b.type.hasGain { line += String(format: " Gain %.1f dB", b.gain) }
            if b.type.hasQ || b.type.hasGain { line += String(format: " Q %.2f", b.q) }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func value(after key: String, in tokens: [String]) -> Double? {
        guard let i = tokens.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }), i + 1 < tokens.count else { return nil }
        return Double(tokens[i + 1].replacingOccurrences(of: ",", with: "."))
    }

    private static func number(after prefix: String, in line: String) -> Double? {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return Double(rest.split(separator: " ").first.map(String.init) ?? "")
    }
}
