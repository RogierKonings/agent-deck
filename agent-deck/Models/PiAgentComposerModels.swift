import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentPasteAttachment: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let marker: String
    let text: String
}

enum PiAgentPasteMarkerCodec {
    static let largePasteLineThreshold = 10
    static let largePasteCharacterThreshold = 1000

    static func normalizedText(from rawText: String) -> String {
        rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
    }

    static func shouldCollapse(_ text: String) -> Bool {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lineCount > largePasteLineThreshold || text.count > largePasteCharacterThreshold
    }

    static func marker(id: Int, text: String) -> String {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if lineCount > largePasteLineThreshold {
            return "[paste #\(id) +\(lineCount) lines]"
        }
        return "[paste #\(id) \(text.count) chars]"
    }

    static func activeAttachments(in text: String, attachments: [PiAgentPasteAttachment]) -> [PiAgentPasteAttachment] {
        guard !attachments.isEmpty, text.contains("[paste #") else { return [] }
        return attachments.filter { text.contains($0.marker) }
    }

    static func expandMarkers(in text: String, attachments: [PiAgentPasteAttachment]) -> String {
        let activeAttachments = activeAttachments(in: text, attachments: attachments)
        guard !activeAttachments.isEmpty else { return text }
        var expanded = text
        for attachment in activeAttachments {
            expanded = expanded.replacingOccurrences(of: attachment.marker, with: attachment.text)
        }
        return expanded
    }
}

