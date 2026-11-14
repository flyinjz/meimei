import Foundation
import AVFoundation
import Accelerate

/// Latest analyzer output for the visualizer. Deliberately not
/// `@Published`: the spectrum view polls it from a `TimelineView`, so
/// incoming audio never invalidates any SwiftUI view.
@MainActor
final class SpectrumFeed {
    private(set) var levels: [Float] = []
    /// Fine log-spaced spectrum in dBFS for the EQ editor; empty unless
    /// `SpectrumAnalyzer.wantsDetail` is set.
    private(set) var detail: [Float] = []
    /// Highest sample of the last buffer, in dBFS (post-EQ, pre-volume).
    private(set) var peakDB: Float = -120
    private(set) var updatedAt = Date.distantPast

    func receive(_ frame: SpectrumAnalyzer.Frame) {
        levels = frame.bands
        detail = frame.detail
        peakDB = frame.peakDB
        updatedAt = Date()
    }

    func silence() {
        levels = levels.map { _ in 0 }
        detail = detail.map { _ in -120 }
        peakDB = -120
        updatedAt = Date()
    }

    /// Band count the analyzer produces; the view picks it from settings.
    nonisolated var bandCount: Int {
        get { SpectrumAnalyzer.bandCount.value }
        set { SpectrumAnalyzer.bandCount.value = max(4, min(96, newValue)) }
    }
}

/// FFT band analysis for the tap thread. Buffers are allocated once; only
/// the small band array is created per call.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = LockedValue(32)
    /// Set while a view shows the detailed spectrum.
    static let wantsDetail = LockedValue(false)
    static let detailCount = 192

    struct Frame: Sendable {
        var bands: [Float]
        var detail: [Float]
        var peakDB: Float
    }

    private let fftSize = 4096
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var mono: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var referencePower: Float = 1

    private var layout: (rate: Double, bands: Int, edges: [Int], tilt: [Float])?
    private var detailLayout: (rate: Double, edges: [Int], tilt: [Float])?

    /// Displayed range, in dB relative to a full-scale sine.
    private let floorDB: Float = -78
    private let ceilingDB: Float = -12

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        mono = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        calibrate()
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Measures the peak bin power of a full-scale sine so levels can be
    /// reported in dBFS regardless of FFT size or window scaling.
    private func calibrate() {
        let bin = Float(fftSize / 8)
        for i in 0..<fftSize {
            mono[i] = sin(2 * .pi * bin * Float(i) / Float(fftSize))
        }
        transform()
        referencePower = max(power.max() ?? 1, .leastNonzeroMagnitude)
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Frame? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }

        var peak: Float = 0
        for c in 0..<channelCount {
            var m: Float = 0
            vDSP_maxmgv(channels[c], 1, &m, vDSP_Length(frames))
            peak = max(peak, m)
        }

        // Most recent `fftSize` frames, channels averaged to mono.
        let count = min(frames, fftSize)
        let offset = frames - count
        mono.withUnsafeMutableBufferPointer { dst in
            vDSP_vclr(dst.baseAddress!, 1, vDSP_Length(fftSize))
            var scale = 1 / Float(channelCount)
            for c in 0..<channelCount {
                vDSP_vsma(channels[c] + offset, 1, &scale, dst.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(count))
            }
        }
        transform()

        let bands = max(4, Self.bandCount.value)
        let shape = layoutFor(rate: buffer.format.sampleRate, bands: bands)
        var levels = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let lo = shape.edges[b], hi = max(shape.edges[b] + 1, shape.edges[b + 1])
            var peak: Float = 0
            for k in lo..<min(hi, power.count) where power[k] > peak { peak = power[k] }
            let db = 10 * log10f(max(peak / referencePower, 1e-12)) + shape.tilt[b]
            levels[b] = max(0, min(1, (db - floorDB) / (ceilingDB - floorDB)))
        }
        return Frame(bands: levels, detail: Self.wantsDetail.value ? detailLevels(rate: buffer.format.sampleRate) : [],
                     peakDB: 20 * log10f(max(peak, 1e-6)))
    }

    /// `detailCount` log-spaced points from 20 Hz to 20 kHz, in dBFS with
    /// a +4.5 dB/octave tilt around 1 kHz (the usual analyzer slope).
    private func detailLevels(rate: Double) -> [Float] {
        if detailLayout?.rate != rate {
            let binHz = rate / Double(fftSize)
            let n = Self.detailCount
            var edges: [Int] = []
            var tilt: [Float] = []
            for i in 0...n {
                let hz = 20 * pow(1000, Double(i) / Double(n))
                edges.append(max(1, min(fftSize / 2 - 1, Int((hz / binHz).rounded()))))
                tilt.append(Float(4.5 * log2(hz / 1000)))
            }
            detailLayout = (rate, edges, tilt)
        }
        guard let shape = detailLayout else { return [] }
        return (0..<Self.detailCount).map { i in
            let lo = shape.edges[i], hi = max(lo + 1, shape.edges[i + 1])
            var peak: Float = 0
            for k in lo..<min(hi, power.count) where power[k] > peak { peak = power[k] }
            return max(-120, 10 * log10f(max(peak / referencePower, 1e-12)) + shape.tilt[i])
        }
    }

    private func transform() {
        let half = fftSize / 2
        mono.withUnsafeMutableBufferPointer { m in
            vDSP_vmul(m.baseAddress!, 1, window, 1, m.baseAddress!, 1, vDSP_Length(fftSize))
        }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                mono.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        power[0] = 0 // DC and Nyquist share bin 0 in zrip's packed format.
    }

    /// Log-spaced band edges from 30 Hz to 16 kHz, plus a +3 dB/octave tilt
    /// so music's natural treble roll-off doesn't leave the right side flat.
    private func layoutFor(rate: Double, bands: Int) -> (rate: Double, bands: Int, edges: [Int], tilt: [Float]) {
        if let layout, layout.rate == rate, layout.bands == bands { return layout }
        let binHz = rate / Double(fftSize)
        let lowHz = 30.0, highHz = min(16_000, rate / 2)
        var edges: [Int] = []
        var tilt: [Float] = []
        for i in 0...bands {
            let hz = lowHz * pow(highHz / lowHz, Double(i) / Double(bands))
            edges.append(max(1, min(fftSize / 2 - 1, Int((hz / binHz).rounded()))))
        }
        // Keep every band at least one bin wide.
        for i in 1..<edges.count where edges[i] <= edges[i - 1] {
            edges[i] = min(fftSize / 2, edges[i - 1] + 1)
        }
        for i in 0..<bands {
            let center = lowHz * pow(highHz / lowHz, (Double(i) + 0.5) / Double(bands))
            tilt.append(Float(3 * log2(center / 1000)))
        }
        let result = (rate, bands, edges, tilt)
        layout = result
        return result
    }
}

/// A tiny lock-protected box for values shared with the audio tap thread.
final class LockedValue<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
