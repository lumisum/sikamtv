import Foundation

enum SubtitleFormat {
    case lrc
    case srt
}

enum LRCParser {
    private static let pattern = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?\](.*)"#)
    private static let htmlTagPattern = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    static func parse(_ text: String) -> [LRCLine] {
        var result: [LRCLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = pattern.firstMatch(in: rawLine, range: range), match.numberOfRanges == 5 else { continue }
            func capture(_ index: Int) -> String? {
                guard let r = Range(match.range(at: index), in: rawLine) else { return nil }
                return String(rawLine[r])
            }
            guard let minutes = Double(capture(1) ?? ""), let seconds = Double(capture(2) ?? "") else { continue }
            let fractionText = capture(3) ?? "0"
            let fraction = fractionText.isEmpty ? 0 : (Double("0." + fractionText) ?? 0)
            let lyric = (capture(4) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(LRCLine(time: minutes * 60 + seconds + fraction, text: lyric))
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Parses SubRip subtitles and converts each cue into the same line model used by the renderer.
    /// SRT end times are intentionally not stored in V1 because the renderer only needs the next
    /// cue's start time to animate the transition.
    static func parseSRT(_ text: String) -> [LRCLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [LRCLine] = []
        var index = 0

        while index < lines.count {
            while index < lines.count && lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { index += 1 }
            guard index < lines.count else { break }

            // A cue may have an optional numeric sequence number.
            if Int(lines[index].trimmingCharacters(in: .whitespacesAndNewlines)) != nil { index += 1 }
            guard index < lines.count, let startTime = parseSRTStartTime(lines[index]) else {
                index += 1
                continue
            }
            index += 1

            var cueText: [String] = []
            while index < lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                if line.isEmpty { break }
                cueText.append(line)
            }
            let joinedText = cueText.joined(separator: " ")
            let cleanText = htmlTagPattern.stringByReplacingMatches(in: joinedText, range: NSRange(joinedText.startIndex..<joinedText.endIndex, in: joinedText), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanText.isEmpty { result.append(LRCLine(time: startTime, text: cleanText)) }
        }
        return result.sorted { $0.time < $1.time }
    }

    static func parse(_ text: String, format: SubtitleFormat) -> [LRCLine] {
        switch format {
        case .lrc: return parse(text)
        case .srt: return parseSRT(text)
        }
    }

    private static func parseSRTStartTime(_ line: String) -> Double? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let start = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = start.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func currentIndex(at time: Double, in lines: [LRCLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var answer: Int?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].time <= time {
                answer = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return answer
    }
}
