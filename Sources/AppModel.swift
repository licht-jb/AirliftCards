import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published var snapshot: FetchResponse?
    @Published var selectedCardID: String?
    @Published var statusText: LocalizedStringResource = L10n.searchingDevices
    @Published var isBusy = false
    @Published var errorMessage: UserFacingText?
    @Published var successMessage: LocalizedStringResource?
    @Published private var currentArtworkURLs: [String: URL] = [:]

    private let backend = BackendRunner()

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedCard: Card? {
        snapshot?.cards.first { $0.id == selectedCardID }
    }

    var cards: [Card] { snapshot?.cards ?? [] }

    var canFetch: Bool { selectedDevice != nil && !isBusy }

    func currentArtworkURL(for card: Card) -> URL {
        currentArtworkURLs[card.id] ?? card.thumbnailURL
    }

    func refreshDevices() async {
        await perform(status: L10n.searchingDevices) {
            let response = try await backend.run(
                DeviceListResponse.self,
                arguments: ["devices"]
            )
            devices = response.devices
            if !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.first(where: \.tested)?.id ?? devices.first?.id
            }
            statusText = devices.isEmpty
                ? L10n.noConnectedDevices
                : L10n.detectedDevices(devices.count)
        }
    }

    func fetchCards() async {
        guard let device = selectedDevice else { return }
        await perform(status: L10n.fetchingCards(from: device.name)) {
            let destination = try makeSnapshotDestination(for: device)
            let response = try await backend.run(
                FetchResponse.self,
                arguments: [
                    "fetch",
                    "--device", device.udid,
                    "--output", destination.path,
                ]
            )
            snapshot = response
            selectedCardID = response.cards.first?.id
            currentArtworkURLs.removeAll()
            statusText = L10n.fetchedCards(response.count)
        }
    }

    func selectCard(_ card: Card) {
        guard selectedCardID != card.id else { return }
        selectedCardID = card.id
    }

    func importFile(_ url: URL) async {
        guard
            let card = selectedCard,
            let artworkURL = card.artworkURL,
            let artworkFileName = card.artworkFileName,
            let snapshot
        else { return }
        await perform(status: L10n.convertingArtwork) {
            let working = URL(fileURLWithPath: snapshot.snapshotPath)
                .appending(path: "Working", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: working,
                withIntermediateDirectories: true
            )
            let input = working.appending(path: "input-\(UUID().uuidString).\(url.pathExtension)")
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            try FileManager.default.copyItem(at: url, to: input)
            let replacement = working.appending(
                path: "replacement-\(UUID().uuidString)-\(artworkFileName)"
            )
            let backups = applicationSupportURL()
                .appending(path: "Backups", directoryHint: .isDirectory)
            _ = try await backend.run(
                FileResponse.self,
                arguments: [
                    "prepare-asset",
                    "--input", input.path,
                    "--artwork", artworkURL.path,
                    "--output", replacement.path,
                    "--card-id", card.id,
                    "--backup-dir", backups.path,
                ]
            )
            statusText = L10n.applyingArtwork
            try await commitArtwork(artwork: replacement, restoration: false)
        }
    }

    func restoreOriginal() async {
        guard
            selectedDevice != nil,
            selectedCard?.canEdit == true,
            !isBusy
        else { return }
        await perform(status: L10n.restoringArtwork) {
            try await commitArtwork(artwork: nil, restoration: true)
        }
    }

    private func commitArtwork(
        artwork: URL?,
        restoration: Bool
    ) async throws {
        guard let device = selectedDevice, let card = selectedCard, let snapshot else {
            throw BackendFailure(
                message: .localized(L10n.selectedCardUnavailable),
                diagnostics: ""
            )
        }
        let backups = applicationSupportURL()
            .appending(path: "Backups", directoryHint: .isDirectory)
        var arguments = [
            restoration ? "restore" : "apply",
            "--device", device.udid,
            "--cards-root", snapshot.cardsRoot,
            "--card-id", card.id,
            "--backup-dir", backups.path,
        ]
        if let artwork {
            arguments.append(contentsOf: ["--replacement", artwork.path])
        }
        arguments.append("--restart-wallet")
        let response = try await backend.run(
            ApplyResponse.self,
            arguments: arguments
        )
        guard response.verifiedPatchedBytes else {
            throw BackendFailure(
                message: .localized(L10n.deviceDataVerificationFailed),
                diagnostics: ""
            )
        }
        currentArtworkURLs[card.id] = URL(
            fileURLWithPath: response.currentArtworkPath
        )
        statusText = restoration
            ? L10n.restoreCacheCleared
            : L10n.applyCacheCleared
        if response.walletRestartRequested && response.walletRestarted {
            successMessage = L10n.walletUpdated
        } else if response.walletRestartRequested {
            successMessage = restoration
                ? L10n.restoreRestartWallet
                : L10n.applyRestartWallet
        } else {
            successMessage = L10n.restartWalletRequired
        }
    }

    private func perform(
        status: LocalizedStringResource,
        operation: () async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        successMessage = nil
        statusText = status
        do {
            try await operation()
        } catch {
            errorMessage = (error as? BackendFailure)?.message
                ?? .verbatim(error.localizedDescription)
            statusText = L10n.operationFailed
        }
        isBusy = false
    }

    private func makeSnapshotDestination(for device: Device) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = applicationSupportURL()
            .appending(path: "Snapshots", directoryHint: .isDirectory)
            .appending(
                path: "\(formatter.string(from: Date()))-\(device.product)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return directory
    }

    private func applicationSupportURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "Airlift Cards", directoryHint: .isDirectory)
    }
}
