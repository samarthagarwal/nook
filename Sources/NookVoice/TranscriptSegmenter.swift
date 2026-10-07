import Foundation

/// Segments transcribed text into timestamped sentences.
/// Used to create the timestamped transcript view in Knowledge recording.
public struct TranscriptSegmenter: Sendable {
    
    /// A segment of text with timing information.
    public struct Segment: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let text: String
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        
        public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
            self.id = UUID()
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
        }
        
        /// Formatted start time (e.g., "0:03").
        public var formattedStartTime: String {
            formatTime(startTime)
        }
        
        /// Formatted end time.
        public var formattedEndTime: String {
            formatTime(endTime)
        }
        
        /// Formatted time range (e.g., "0:03-0:07").
        public var formattedTimeRange: String {
            "\(formattedStartTime)-\(formattedEndTime)"
        }
        
        private func formatTime(_ time: TimeInterval) -> String {
            let minutes = Int(time) / 60
            let seconds = Int(time) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    public init() {}
    
    /// Converts WhisperKit timestamped segments into sentence-based segments.
    /// Groups word-level timestamps by sentence boundaries (., ?, !).
    public func segmentBySentences(
        _ whisperSegments: [WhisperTranscriber.TimestampedSegment]
    ) -> [Segment] {
        // WhisperKit segments are already sentence-based from our conversion
        return whisperSegments.map { segment in
            Segment(
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime
            )
        }
    }
    
    /// Segments raw text with estimated timestamps based on word count.
    /// Used when word-level timestamps aren't available.
    public func segmentWithEstimatedTiming(
        text: String,
        totalDuration: TimeInterval
    ) -> [Segment] {
        let sentences = splitIntoSentences(text)
        guard !sentences.isEmpty else { return [] }
        
        let totalWords = sentences.reduce(0) { $0 + $1.split(separator: " ").count }
        guard totalWords > 0 else { return [] }
        
        let timePerWord = totalDuration / Double(totalWords)
        var currentTime: TimeInterval = 0
        
        return sentences.map { sentence in
            let wordCount = sentence.split(separator: " ").count
            let sentenceDuration = Double(wordCount) * timePerWord
            let startTime = currentTime
            let endTime = currentTime + sentenceDuration
            currentTime = endTime
            
            return Segment(
                text: sentence,
                startTime: startTime,
                endTime: endTime
            )
        }
    }
    
    /// Splits text into sentences based on punctuation.
    private func splitIntoSentences(_ text: String) -> [String] {
        // Use NLTokenizer for better sentence detection
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        
        // Simple regex-based splitting for sentence boundaries
        // Handles: . ? ! and keeps the punctuation with the sentence
        let pattern = #"[^.!?]*[.!?]+"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            // Fallback: return whole text as one segment
            return [text]
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        var sentences: [String] = []
        var lastEnd = text.startIndex
        
        for match in matches {
            if let matchRange = Range(match.range, in: text) {
                let sentence = String(text[matchRange]).trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                lastEnd = matchRange.upperBound
            }
        }
        
        // Add any remaining text without ending punctuation
        if lastEnd < text.endIndex {
            let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty {
                sentences.append(remaining)
            }
        }
        
        return sentences
    }
    
    /// Finds the segment containing a specific timestamp.
    public func findSegment(at timestamp: TimeInterval, in segments: [Segment]) -> Segment? {
        segments.first { segment in
            timestamp >= segment.startTime && timestamp < segment.endTime
        }
    }
    
    /// Returns segments within a time range.
    public func segments(in range: ClosedRange<TimeInterval>, from segments: [Segment]) -> [Segment] {
        segments.filter { segment in
            segment.startTime < range.upperBound && segment.endTime > range.lowerBound
        }
    }
}

// MARK: - Transcript Formatting

public extension TranscriptSegmenter {
    
    /// Formats segments as a markdown string with timestamps.
    func formatAsMarkdown(_ segments: [Segment]) -> String {
        segments.map { segment in
            "**\(segment.formattedStartTime)** \(segment.text)"
        }.joined(separator: "\n\n")
    }
    
    /// Formats segments as plain text without timestamps.
    func formatAsPlainText(_ segments: [Segment]) -> String {
        segments.map { $0.text }.joined(separator: " ")
    }
    
    /// Generates a title from the transcript using the first sentence.
    /// If the first sentence is too long, truncates with ellipsis.
    func suggestTitle(from segments: [Segment], maxLength: Int = 50) -> String {
        guard let first = segments.first else { return "Voice note" }
        
        var title = first.text
        
        // Remove trailing punctuation
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        
        // Truncate if too long
        if title.count > maxLength {
            let truncated = String(title.prefix(maxLength))
            if let lastSpace = truncated.lastIndex(of: " ") {
                title = String(truncated[..<lastSpace]) + "…"
            } else {
                title = truncated + "…"
            }
        }
        
        return title
    }
}
