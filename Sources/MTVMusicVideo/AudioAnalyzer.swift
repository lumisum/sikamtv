import Accelerate
import AVFoundation
import Foundation

enum AudioAnalyzerError: Error { case cannotOpenFile }

/// Produces reusable, frame-aligned musical features. It streams PCM instead of
/// retaining the whole song and reuses FFT buffers to avoid thousands of allocations.
final class AudioAnalyzer {
    private let frameRate = 30.0
    private let fftSize = 4096
    private let bandCount = 96
    private let waveformPointCount = 128

    func analyze(url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> AudioAnalysis {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameTotal = Int(file.length)
        guard frameTotal > 0, format.sampleRate > 0 else { throw AudioAnalyzerError.cannotOpenFile }

        let channels = max(1, Int(format.channelCount))
        let hopSize = max(512, Int(format.sampleRate / frameRate))
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw AudioAnalyzerError.cannotOpenFile
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let bandRanges = makeBandRanges(sampleRate: format.sampleRate)

        var fftInput = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var normalized = [Float](repeating: 0, count: bandCount)
        var previousSpectrum = [Float](repeating: 0, count: bandCount)
        var pending: [Float] = []
        pending.reserveCapacity(65_536)
        var pendingHead = 0

        var amplitudes: [Float] = []
        var loudness: [Float] = []
        var bassValues: [Float] = []
        var midValues: [Float] = []
        var highValues: [Float] = []
        var beatValues: [Float] = []
        var spectra: [[Float]] = []
        var waveforms: [[Float]] = []
        let expectedFrames = Int(ceil(Double(frameTotal) / Double(hopSize)))
        for storage in [expectedFrames] { // Keep capacity setup compact and explicit.
            amplitudes.reserveCapacity(storage); loudness.reserveCapacity(storage)
            bassValues.reserveCapacity(storage); midValues.reserveCapacity(storage)
            highValues.reserveCapacity(storage); beatValues.reserveCapacity(storage)
            spectra.reserveCapacity(storage); waveforms.reserveCapacity(storage)
        }

        var previousAmplitude: Float = 0
        var adaptiveRMSPeak: Float = 0.08
        var adaptiveSpectrumPeak: Float = 0.12
        var fluxHistory: [Float] = []
        fluxHistory.reserveCapacity(48)
        var previousFluxSpectrum = [Float](repeating: 0, count: bandCount)
        var lastBeatFrame = -100
        var beatEnvelope: Float = 0
        var processedSamples = 0
        var lastProgress = -1.0

        func processFrame() {
            let available = min(fftSize, pending.count - pendingHead)
            guard available > 0 else { return }
            for index in 0..<fftSize {
                let sample = index < available ? pending[pendingHead + index] : 0
                fftInput[index] = sample * hann[index]
            }

            var rms: Float = 0
            vDSP_rmsqv(fftInput, 1, &rms, vDSP_Length(available))
            adaptiveRMSPeak = max(rms, adaptiveRMSPeak * 0.997)
            let rawLevel = min(1, rms / max(0.025, adaptiveRMSPeak * 0.82))
            let amplitude = previousAmplitude * 0.68 + pow(rawLevel, 0.72) * 0.32
            previousAmplitude = amplitude

            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    fftInput.withUnsafeBufferPointer { source in
                        source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                }
            }

            var framePeak: Float = 0
            for band in 0..<bandCount {
                let range = bandRanges[band]
                var peak: Float = 0
                for bin in range { peak = max(peak, magnitudes[bin]) }
                let linear = sqrt(max(0, peak)) / Float(fftSize) * 7.5
                normalized[band] = linear
                framePeak = max(framePeak, linear)
            }
            adaptiveSpectrumPeak = max(framePeak, adaptiveSpectrumPeak * 0.995)
            for index in normalized.indices {
                let gained = min(1, normalized[index] / max(0.018, adaptiveSpectrumPeak * 0.78))
                let shaped = pow(gained, 0.68)
                let coefficient: Float = shaped > previousSpectrum[index] ? 0.58 : 0.14
                normalized[index] = previousSpectrum[index] + (shaped - previousSpectrum[index]) * coefficient
            }

            let bass = average(normalized, frequencies: bandRanges, sampleRate: format.sampleRate, from: 35, to: 220)
            let mid = average(normalized, frequencies: bandRanges, sampleRate: format.sampleRate, from: 220, to: 2_400)
            let high = average(normalized, frequencies: bandRanges, sampleRate: format.sampleRate, from: 2_400, to: 16_000)
            var flux: Float = 0
            for index in normalized.indices { flux += max(0, normalized[index] - previousFluxSpectrum[index]) }
            flux /= Float(bandCount)
            let fluxMean = fluxHistory.isEmpty ? 0 : fluxHistory.reduce(0, +) / Float(fluxHistory.count)
            let frameIndex = amplitudes.count
            let isBeat = frameIndex - lastBeatFrame > Int(frameRate * 0.18)
                && flux > max(0.012, fluxMean * 1.52)
                && (bass > 0.20 || amplitude > 0.55)
            if isBeat { lastBeatFrame = frameIndex; beatEnvelope = 1 }
            else { beatEnvelope *= 0.78 }
            fluxHistory.append(flux)
            if fluxHistory.count > 45 { fluxHistory.removeFirst() }

            var waveform = [Float](repeating: 0, count: waveformPointCount)
            let stride = max(1, available / waveformPointCount)
            for point in 0..<waveformPointCount {
                let source = min(available - 1, point * stride)
                waveform[point] = max(-1, min(1, pending[pendingHead + source] / max(0.08, adaptiveRMSPeak * 3.2)))
            }

            amplitudes.append(amplitude)
            loudness.append(min(1, pow(max(0, rawLevel), 0.55)))
            bassValues.append(bass)
            midValues.append(mid)
            highValues.append(high)
            beatValues.append(beatEnvelope)
            spectra.append(normalized)
            waveforms.append(waveform)
            previousSpectrum = normalized
            previousFluxSpectrum = normalized
        }

        let chunkCapacity = 32_768
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkCapacity))!
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(Int64(chunkCapacity), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: requested)
            let count = Int(buffer.frameLength)
            guard count > 0, let channelData = buffer.floatChannelData else { throw AudioAnalyzerError.cannotOpenFile }
            for sampleIndex in 0..<count {
                var sample: Float = 0
                for channel in 0..<channels { sample += channelData[channel][sampleIndex] }
                pending.append(sample / Float(channels))
            }

            while pending.count - pendingHead >= fftSize {
                try Task.checkCancellation()
                processFrame()
                pendingHead += hopSize
                processedSamples += hopSize
            }
            if pendingHead > 65_536 {
                pending.removeFirst(pendingHead)
                pendingHead = 0
            }
            let currentProgress = min(0.98, Double(processedSamples) / Double(frameTotal))
            if currentProgress - lastProgress >= 0.02 {
                progress?(currentProgress)
                lastProgress = currentProgress
            }
        }
        if pending.count > pendingHead { processFrame() }
        let structure = makeMusicalStructure(
            loudness: loudness,
            bass: bassValues,
            mid: midValues,
            high: highValues,
            beats: beatValues
        )
        progress?(1)

        return AudioAnalysis(
            duration: Double(frameTotal) / format.sampleRate,
            sampleRate: format.sampleRate,
            frameRate: frameRate,
            amplitudes: amplitudes,
            loudness: loudness,
            bass: bassValues,
            mid: midValues,
            high: highValues,
            beats: beatValues,
            spectrum: spectra,
            waveform: waveforms,
            energy: structure.energy,
            transients: structure.transients,
            buildups: structure.buildups,
            climaxes: structure.climaxes,
            quietness: structure.quietness,
            warmth: structure.warmth,
            sectionProgress: structure.sectionProgress
        )
    }

    private struct MusicalStructure {
        let energy: [Float]
        let transients: [Float]
        let buildups: [Float]
        let climaxes: [Float]
        let quietness: [Float]
        let warmth: [Float]
        let sectionProgress: [Float]
    }

    /// Looks across the complete song after the streaming FFT pass. These slow
    /// envelopes provide musical context without adding work to preview frames.
    private func makeMusicalStructure(
        loudness: [Float],
        bass: [Float],
        mid: [Float],
        high: [Float],
        beats: [Float]
    ) -> MusicalStructure {
        let count = loudness.count
        guard count > 0 else {
            return MusicalStructure(energy: [], transients: [], buildups: [], climaxes: [], quietness: [], warmth: [], sectionProgress: [])
        }
        var rawEnergy = [Float](repeating: 0, count: count)
        var warmth = [Float](repeating: 0.5, count: count)
        for index in 0..<count {
            let low = value(bass, index)
            let middle = value(mid, index)
            let treble = value(high, index)
            rawEnergy[index] = value(loudness, index) * 0.42 + low * 0.28 + middle * 0.20 + treble * 0.10
            warmth[index] = max(0, min(1, 0.5 + (low - treble) * 0.72))
        }

        let short = movingAverage(rawEnergy, radius: Int(frameRate * 0.32))
        let phrase = movingAverage(rawEnergy, radius: Int(frameRate * 1.8))
        let sorted = phrase.sorted()
        let floor = sorted[min(sorted.count - 1, Int(Float(sorted.count - 1) * 0.08))]
        let ceiling = sorted[min(sorted.count - 1, Int(Float(sorted.count - 1) * 0.92))]
        let span = max(0.04, ceiling - floor)
        let energy = phrase.map { smoothstep(($0 - floor) / span) }

        var transients = [Float](repeating: 0, count: count)
        var buildups = [Float](repeating: 0, count: count)
        var climaxes = [Float](repeating: 0, count: count)
        let look = max(1, Int(frameRate * 1.6))
        let beatDensity = movingAverage(beats, radius: Int(frameRate * 0.7))
        for index in 0..<count {
            let previous = short[max(0, index - 2)]
            let rise = max(0, short[index] - previous) * 5.5
            transients[index] = max(value(beats, index), min(1, rise))
            let future = phrase[min(count - 1, index + look)]
            let past = phrase[max(0, index - look)]
            buildups[index] = smoothstep(max(0, (future - phrase[index]) * 2.8 + (phrase[index] - past) * 1.35))
            let intensity = energy[index] * 0.72 + min(1, beatDensity[index] * 2.4) * 0.28
            climaxes[index] = smoothstep((intensity - 0.52) / 0.48)
        }
        transients = asymmetricSmooth(transients, attack: 0.72, release: 0.18)
        buildups = movingAverage(buildups, radius: Int(frameRate * 0.38))
        climaxes = movingAverage(climaxes, radius: Int(frameRate * 0.55))
        let quietness = energy.map { smoothstep((0.42 - $0) / 0.42) }
        warmth = movingAverage(warmth, radius: Int(frameRate * 0.8))
        let sectionProgress = detectSectionProgress(energy: energy, warmth: warmth)
        return MusicalStructure(
            energy: energy,
            transients: transients,
            buildups: buildups,
            climaxes: climaxes,
            quietness: quietness,
            warmth: warmth,
            sectionProgress: sectionProgress
        )
    }

    private func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        guard !values.isEmpty, radius > 0 else { return values }
        var prefix = [Float](repeating: 0, count: values.count + 1)
        for index in values.indices { prefix[index + 1] = prefix[index] + values[index] }
        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count, index + radius + 1)
            return (prefix[upper] - prefix[lower]) / Float(upper - lower)
        }
    }

    private func asymmetricSmooth(_ values: [Float], attack: Float, release: Float) -> [Float] {
        var result = [Float](repeating: 0, count: values.count)
        var envelope: Float = 0
        for index in values.indices {
            let coefficient = values[index] > envelope ? attack : release
            envelope += (values[index] - envelope) * coefficient
            result[index] = envelope
        }
        return result
    }

    private func detectSectionProgress(energy: [Float], warmth: [Float]) -> [Float] {
        guard !energy.isEmpty else { return [] }
        let window = max(1, Int(frameRate * 1.4))
        let minimumSection = max(1, Int(frameRate * 4.0))
        var boundaries = [0]
        var lastBoundary = 0
        if energy.count > window * 2 {
            for index in window..<(energy.count - window) {
                guard index - lastBoundary >= minimumSection else { continue }
                let energyChange = abs(energy[index + window] - energy[index - window])
                let colorChange = abs(warmth[index + window] - warmth[index - window])
                if energyChange + colorChange * 0.45 > 0.26 {
                    boundaries.append(index)
                    lastBoundary = index
                }
            }
        }
        boundaries.append(energy.count)
        var progress = [Float](repeating: 0, count: energy.count)
        for boundaryIndex in 0..<(boundaries.count - 1) {
            let start = boundaries[boundaryIndex]
            let end = boundaries[boundaryIndex + 1]
            let length = max(1, end - start)
            for index in start..<end { progress[index] = Float(index - start) / Float(length) }
        }
        return progress
    }

    private func smoothstep(_ value: Float) -> Float {
        let x = max(0, min(1, value))
        return x * x * (3 - 2 * x)
    }

    private func value(_ values: [Float], _ index: Int) -> Float {
        values.isEmpty ? 0 : values[min(index, values.count - 1)]
    }

    private func makeBandRanges(sampleRate: Double) -> [Range<Int>] {
        let nyquist = sampleRate / 2
        let minimum = 28.0
        let maximum = min(20_000, nyquist)
        return (0..<bandCount).map { band in
            let startFrequency = minimum * pow(maximum / minimum, Double(band) / Double(bandCount))
            let endFrequency = minimum * pow(maximum / minimum, Double(band + 1) / Double(bandCount))
            let start = max(1, min(fftSize / 2 - 1, Int(startFrequency / sampleRate * Double(fftSize))))
            let end = max(start + 1, min(fftSize / 2, Int(endFrequency / sampleRate * Double(fftSize))))
            return start..<end
        }
    }

    private func average(_ values: [Float], frequencies ranges: [Range<Int>], sampleRate: Double, from: Double, to: Double) -> Float {
        var total: Float = 0
        var count: Float = 0
        for (index, range) in ranges.enumerated() {
            let centerBin = Double(range.lowerBound + range.upperBound) * 0.5
            let frequency = centerBin / Double(fftSize) * sampleRate
            if frequency >= from, frequency < to { total += values[index]; count += 1 }
        }
        return count > 0 ? total / count : 0
    }
}

final class AudioAnalysisCache: @unchecked Sendable {
    static let shared = AudioAnalysisCache()
    private struct Payload: Codable {
        let version: Int
        let duration: Double
        let sampleRate: Double
        let frameRate: Double
        let frameCount: Int
        let spectrumWidth: Int
        let waveformWidth: Int
        let amplitudes: Data
        let loudness: Data
        let bass: Data
        let mid: Data
        let high: Data
        let beats: Data
        let energy: Data
        let transients: Data
        let buildups: Data
        let climaxes: Data
        let quietness: Data
        let warmth: Data
        let sectionProgress: Data
        let spectrum: Data
        let waveform: Data
    }
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    private init() { encoder.outputFormat = .binary }

    func load(for url: URL) -> AudioAnalysis? {
        let cacheURL = location(for: url)
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == AudioAnalysis.cacheVersion else { return nil }
        let amplitudes = floats(payload.amplitudes)
        guard amplitudes.count == payload.frameCount else { return nil }
        return AudioAnalysis(
            version: payload.version,
            duration: payload.duration,
            sampleRate: payload.sampleRate,
            frameRate: payload.frameRate,
            amplitudes: amplitudes,
            loudness: floats(payload.loudness),
            bass: floats(payload.bass),
            mid: floats(payload.mid),
            high: floats(payload.high),
            beats: floats(payload.beats),
            spectrum: rows(payload.spectrum, width: payload.spectrumWidth),
            waveform: rows(payload.waveform, width: payload.waveformWidth),
            energy: floats(payload.energy),
            transients: floats(payload.transients),
            buildups: floats(payload.buildups),
            climaxes: floats(payload.climaxes),
            quietness: floats(payload.quietness),
            warmth: floats(payload.warmth),
            sectionProgress: floats(payload.sectionProgress)
        )
    }

    func save(_ analysis: AudioAnalysis, for url: URL) {
        let cacheURL = location(for: url)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let spectrumWidth = analysis.spectrum.first?.count ?? 0
        let waveformWidth = analysis.waveform.first?.count ?? 0
        let payload = Payload(
            version: analysis.version,
            duration: analysis.duration,
            sampleRate: analysis.sampleRate,
            frameRate: analysis.frameRate,
            frameCount: analysis.amplitudes.count,
            spectrumWidth: spectrumWidth,
            waveformWidth: waveformWidth,
            amplitudes: bytes(analysis.amplitudes),
            loudness: bytes(analysis.loudness),
            bass: bytes(analysis.bass),
            mid: bytes(analysis.mid),
            high: bytes(analysis.high),
            beats: bytes(analysis.beats),
            energy: bytes(analysis.energy),
            transients: bytes(analysis.transients),
            buildups: bytes(analysis.buildups),
            climaxes: bytes(analysis.climaxes),
            quietness: bytes(analysis.quietness),
            warmth: bytes(analysis.warmth),
            sectionProgress: bytes(analysis.sectionProgress),
            spectrum: bytes(flatten(analysis.spectrum, width: spectrumWidth)),
            waveform: bytes(flatten(analysis.waveform, width: waveformWidth))
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func bytes(_ values: [Float]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    private func flatten(_ rows: [[Float]], width: Int) -> [Float] {
        guard width > 0 else { return [] }
        var result: [Float] = []
        result.reserveCapacity(rows.count * width)
        for row in rows { result.append(contentsOf: row.prefix(width)) }
        return result
    }

    private func rows(_ data: Data, width: Int) -> [[Float]] {
        guard width > 0 else { return [] }
        let values = floats(data)
        var result: [[Float]] = []
        result.reserveCapacity(values.count / width)
        var index = 0
        while index + width <= values.count {
            result.append(Array(values[index..<(index + width)]))
            index += width
        }
        return result
    }

    private func location(for url: URL) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        let identity = "\(url.standardizedFileURL.path)|\(size?.int64Value ?? 0)|\(modified?.timeIntervalSince1970 ?? 0)|\(AudioAnalysis.cacheVersion)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("SikaMTV/AudioAnalysis", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16)).appendingPathExtension("plist")
    }
}
