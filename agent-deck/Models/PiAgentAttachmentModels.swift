import Foundation

// MARK: - Composer attachments

struct PiAgentImageAttachment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var mimeType: String
    var data: String
    var sizeBytes: Int
    var fileReference: String?
    var dimensionNote: String?

    nonisolated init(id: UUID = UUID(), name: String, mimeType: String, data: String, sizeBytes: Int, fileReference: String? = nil, dimensionNote: String? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.sizeBytes = sizeBytes
        self.fileReference = fileReference
        self.dimensionNote = dimensionNote
    }

    nonisolated var rpcPayload: [String: String] {
        ["type": "image", "data": data, "mimeType": mimeType]
    }
}

struct PiAgentModelOption: Identifiable, Codable, Hashable {
    var provider: String
    var id: String
    var name: String?
    var contextWindow: Int?
    var maxOutput: Int?
    var supportsThinking: Bool?
    var supportedThinkingLevels: [String]?
    var supportsImages: Bool?

    var displayName: String { name?.isEmpty == false ? name! : id }
    var selectionID: String { "\(provider)/\(id)" }

    init(
        provider: String,
        id: String,
        name: String?,
        contextWindow: Int?,
        maxOutput: Int? = nil,
        supportsThinking: Bool?,
        supportedThinkingLevels: [String]?,
        supportsImages: Bool?
    ) {
        self.provider = provider
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.supportsThinking = supportsThinking
        self.supportedThinkingLevels = supportedThinkingLevels
        self.supportsImages = supportsImages
    }
}
