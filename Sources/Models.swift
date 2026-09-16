import Foundation

struct Device: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let model: String
    let product: String
    let version: String
    let build: String
    let transport: String
    let tested: Bool
    let udid: String

    var id: String { udid }

    var detail: String {
        "\(model) · iOS \(version) · \(transport)"
    }
}

struct Card: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let thumbnailPath: String
    let artworkPath: String?
    let artworkFileName: String?

    var thumbnailURL: URL { URL(fileURLWithPath: thumbnailPath) }
    var artworkURL: URL? {
        artworkPath.map { URL(fileURLWithPath: $0) }
    }
    var canEdit: Bool { artworkURL != nil }
}

struct DeviceListResponse: Decodable, Sendable {
    let ok: Bool
    let devices: [Device]
}

struct FetchResponse: Decodable, Sendable {
    let ok: Bool
    let snapshotPath: String
    let cardsRoot: String
    let count: Int
    let cards: [Card]
}

struct FileResponse: Decodable, Sendable {
    let ok: Bool
    let outputPath: String
    let width: Int
    let height: Int
}

struct ApplyResponse: Decodable, Sendable {
    let ok: Bool
    let cardID: String
    let backupPath: String
    let currentArtworkPath: String
    let verifiedPatchedBytes: Bool
    let walletRestartRequested: Bool
    let walletRestarted: Bool
    let walletRestartError: String?
}

struct ErrorResponse: Decodable {
    let error: String
}
