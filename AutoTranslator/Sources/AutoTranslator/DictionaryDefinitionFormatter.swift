import Foundation

struct DictionaryDisplayEntry {
    struct Line {
        enum Kind {
            case section
            case sense
            case example
            case keyValue
            case body
        }

        let kind: Kind
        let text: String
        let key: String?
        let value: String?
        let marker: String?
    }

    let title: String
    let pronunciation: String?
    let lines: [Line]

    nonisolated var measurementText: String {
        var parts: [String] = [title]
        if let pronunciation, !pronunciation.isEmpty {
            parts.append(pronunciation)
        }
        parts.append(contentsOf: lines.map(\.text))
        return parts.joined(separator: "\n")
    }
}

enum DictionaryDefinitionFormatter {
    nonisolated private static let circledNumbers = "①②③④⑤⑥⑦⑧⑨⑩"
    nonisolated private static let sectionTitles = [
        "PHRASAL VERBS",
        "IDIOMS",
        "DERIVATIVES",
        "COMPOUNDS",
    ]

    nonisolated static func entry(word: String, definition: String) -> DictionaryDisplayEntry {
        let fallbackTitle = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = fallbackTitle.isEmpty ? "词典" : fallbackTitle
        var pronunciation: String?
        var body = normalizedWhitespace(definition)

        if let pipeHeader = parsePipeHeader(body: body) {
            title = pipeHeader.title
            pronunciation = pipeHeader.pronunciation
            body = pipeHeader.body
        } else if let lineHeader = parseLineHeader(body: body) {
            title = lineHeader.title
            body = lineHeader.body
        }

        let formattedBody = insertReadableBreaks(in: body)
        let lines = formattedBody
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(classifyLine)

        return DictionaryDisplayEntry(
            title: title,
            pronunciation: pronunciation,
            lines: lines.isEmpty ? [classifyLine(body)] : lines
        )
    }

    nonisolated static func measurementText(word: String, definition: String) -> String {
        entry(word: word, definition: definition).measurementText
    }

    nonisolated private static func parsePipeHeader(
        body: String
    ) -> (title: String, pronunciation: String?, body: String)? {
        let parts = body.components(separatedBy: " | ")
        guard parts.count >= 3 else { return nil }

        let candidateTitle = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateTitle.isEmpty,
              candidateTitle.count <= 64,
              candidateTitle.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        let title = candidateTitle
        let pronunciation = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = parts.dropFirst(2).joined(separator: " | ")
        return (
            title: title,
            pronunciation: pronunciation.isEmpty ? nil : pronunciation,
            body: remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    nonisolated private static func parseLineHeader(body: String) -> (title: String, body: String)? {
        guard let newline = body.firstIndex(of: "\n") else { return nil }
        let firstLine = String(body[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty,
              firstLine.count <= 72,
              firstLine.range(of: "：") == nil,
              firstLine.range(of: ":") == nil else {
            return nil
        }

        let remaining = String(body[body.index(after: newline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return nil }
        return (title: firstLine, body: remaining)
    }

    nonisolated private static func normalizedWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func insertReadableBreaks(in body: String) -> String {
        var text = normalizedWhitespace(body)

        for title in sectionTitles {
            text = replacing(
                pattern: "\\s*\(NSRegularExpression.escapedPattern(for: title))\\s*",
                in: text,
                template: "\n\(title)\n"
            )
        }

        text = replacing(pattern: "\\s*▸\\s*", in: text, template: "\n▸ ")
        text = replacing(pattern: "\\s*([\(circledNumbers)])\\s*", in: text, template: "\n$1 ")
        text = replacing(pattern: "\\s+([A-Z]\\.\\s+)", in: text, template: "\n$1")
        text = replacing(pattern: "\\n{3,}", in: text, template: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func classifyLine(_ rawLine: String) -> DictionaryDisplayEntry.Line {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            return DictionaryDisplayEntry.Line(kind: .body, text: line, key: nil, value: nil, marker: nil)
        }

        if sectionTitles.contains(line.uppercased()) || isLetteredSection(line) {
            return DictionaryDisplayEntry.Line(kind: .section, text: line, key: nil, value: nil, marker: nil)
        }

        if line.hasPrefix("▸") {
            let value = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            return DictionaryDisplayEntry.Line(kind: .example, text: line, key: nil, value: value, marker: "▸")
        }

        if let first = line.first, circledNumbers.contains(first) {
            let value = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            return DictionaryDisplayEntry.Line(kind: .sense, text: line, key: nil, value: value, marker: String(first))
        }

        if let keyValue = parseKeyValue(line) {
            return DictionaryDisplayEntry.Line(
                kind: .keyValue,
                text: line,
                key: keyValue.key,
                value: keyValue.value,
                marker: nil
            )
        }

        return DictionaryDisplayEntry.Line(kind: .body, text: line, key: nil, value: nil, marker: nil)
    }

    nonisolated private static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        let separators = ["：", ":"]
        for separator in separators {
            guard let range = line.range(of: separator) else { continue }
            let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, key.count <= 8 else { continue }
            return (key, value)
        }
        return nil
    }

    nonisolated private static func isLetteredSection(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let prefix = line.prefix(3)
        guard prefix.dropFirst().hasPrefix(".") else { return false }
        return prefix.first?.isUppercase == true
    }

    nonisolated private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
