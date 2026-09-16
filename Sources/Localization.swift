import Foundation

enum L10n {
    static let replaceArtwork: LocalizedStringResource =
        "action.replaceArtwork"
    static let restoreOriginal: LocalizedStringResource =
        "action.restoreOriginal"
    static let cancel: LocalizedStringResource = "action.cancel"
    static let close: LocalizedStringResource = "action.close"
    static let ok: LocalizedStringResource = "action.ok"

    static let failureTitle: LocalizedStringResource = "alert.failure.title"
    static let successTitle: LocalizedStringResource = "alert.success.title"
    static let unknownError: LocalizedStringResource = "error.unknown"

    static let refreshConnectionHelp: LocalizedStringResource =
        "connection.refresh.help"
    static let noDevicesTitle: LocalizedStringResource =
        "devices.empty.title"
    static let noDevicesDescription: LocalizedStringResource =
        "devices.empty.description"
    static let devicePickerLabel: LocalizedStringResource =
        "devices.picker.label"

    static let fetchCards: LocalizedStringResource = "cards.fetch.action"
    static let noCardsTitle: LocalizedStringResource = "cards.empty.title"
    static let noCardsDescription: LocalizedStringResource =
        "cards.empty.description"
    static let cardsNotFetchedTitle: LocalizedStringResource =
        "cards.notFetched.title"
    static let cardsNotFetchedDescription: LocalizedStringResource =
        "cards.notFetched.description"
    static let languageLabel: LocalizedStringResource = "language.label"

    static let searchingDevices: LocalizedStringResource =
        "status.devices.searching"
    static let noConnectedDevices: LocalizedStringResource =
        "status.devices.none"
    static let convertingArtwork: LocalizedStringResource =
        "status.artwork.converting"
    static let applyingArtwork: LocalizedStringResource =
        "status.artwork.applying"
    static let restoringArtwork: LocalizedStringResource =
        "status.artwork.restoring"
    static let restoreCacheCleared: LocalizedStringResource =
        "status.artwork.restoreCacheCleared"
    static let applyCacheCleared: LocalizedStringResource =
        "status.artwork.applyCacheCleared"
    static let operationFailed: LocalizedStringResource =
        "status.operation.failed"

    static let selectedCardUnavailable: LocalizedStringResource =
        "error.card.unavailable"
    static let deviceDataVerificationFailed: LocalizedStringResource =
        "error.deviceData.verificationFailed"
    static let backendFailed: LocalizedStringResource =
        "error.backend.failed"
    static let backendInvalidResponse: LocalizedStringResource =
        "error.backend.invalidResponse"
    static let backendMissing: LocalizedStringResource =
        "error.backend.missing"

    static let walletUpdated: LocalizedStringResource =
        "success.wallet.updated"
    static let restoreRestartWallet: LocalizedStringResource =
        "success.wallet.restoreRestartRequired"
    static let applyRestartWallet: LocalizedStringResource =
        "success.wallet.applyRestartRequired"
    static let restartWalletRequired: LocalizedStringResource =
        "success.wallet.restartRequired"

    static func fetchedCardSummary(_ count: Int) -> LocalizedStringResource {
        "cards.fetch.summary.\(count)"
    }

    static func detectedDevices(_ count: Int) -> LocalizedStringResource {
        "status.devices.detected.\(count)"
    }

    static func fetchingCards(from deviceName: String) -> LocalizedStringResource {
        "status.cards.fetching.\(deviceName)"
    }

    static func fetchedCards(_ count: Int) -> LocalizedStringResource {
        "status.cards.fetched.\(count)"
    }
}
