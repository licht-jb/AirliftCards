import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Binding var languageIdentifier: String
    @State private var isImporterPresented = false
    @State private var isCardActionPresented = false

    var body: some View {
        NavigationSplitView {
            deviceSidebar
        } detail: {
            cardBrowser
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            if model.isBusy {
                loadingIndicator
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                return
            }
            Task { await model.importFile(url) }
        }
        .confirmationDialog(
            model.selectedCard?.title ?? cardActionsTitle,
            isPresented: $isCardActionPresented,
            titleVisibility: .visible
        ) {
            Button {
                isImporterPresented = true
            } label: {
                Text(L10n.replaceArtwork)
            }
            Button(role: .destructive) {
                Task { await model.restoreOriginal() }
            } label: {
                Text(L10n.restoreOriginal)
            }
            Button(role: .cancel) {
            } label: {
                Text(L10n.cancel)
            }
        }
        .alert(
            Text(L10n.failureTitle),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(role: .cancel) {
            } label: {
                Text(L10n.close)
            }
        } message: {
            userFacingText(model.errorMessage)
        }
        .alert(
            Text(L10n.successTitle),
            isPresented: Binding(
                get: { model.successMessage != nil },
                set: { if !$0 { model.successMessage = nil } }
            )
        ) {
            Button(role: .cancel) {
            } label: {
                Text(L10n.ok)
            }
        } message: {
            if let successMessage = model.successMessage {
                Text(successMessage)
            }
        }
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if #available(macOS 26.0, *) {
            ProgressView {
                Text(model.statusText)
            }
                .padding()
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
        } else {
            ProgressView {
                Text(model.statusText)
            }
                .padding()
                .allowsHitTesting(false)
        }
    }

    private var deviceSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("iPhone")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .help(L10n.refreshConnectionHelp)
            }

            if model.devices.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text(L10n.noDevicesTitle)
                    } icon: {
                        Image(systemName: "iphone.slash")
                    }
                } description: {
                    Text(L10n.noDevicesDescription)
                }
            } else {
                Picker(selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                } label: {
                    Text(L10n.devicePickerLabel)
                }
                .labelsHidden()

                if let device = model.selectedDevice {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.detail)
                            .font(.callout)
                        Text(device.product + " · " + device.build)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task { await model.fetchCards() }
            } label: {
                Label {
                    Text(L10n.fetchCards)
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canFetch)

            if let snapshot = model.snapshot {
                Text(L10n.fetchedCardSummary(snapshot.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Divider()
            HStack {
                Label {
                    Text(L10n.languageLabel)
                } icon: {
                    Image(systemName: "globe")
                }
                Spacer()
                Picker(selection: $languageIdentifier) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName)
                            .tag(language.rawValue)
                    }
                } label: {
                    Text(L10n.languageLabel)
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
        .padding()
        .navigationSplitViewColumnWidth(min: 250, ideal: 280)
    }

    @ViewBuilder
    private var cardBrowser: some View {
        if !model.cards.isEmpty {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(model.cards) { card in
                        cardTile(card)
                    }
                }
                .padding()
            }
            .navigationTitle(Text(verbatim: cardListTitle))
            .navigationSplitViewColumnWidth(min: 330, ideal: 560)
        } else if model.snapshot != nil {
            ContentUnavailableView {
                Label {
                    Text(L10n.noCardsTitle)
                } icon: {
                    Image(systemName: "creditcard.trianglebadge.exclamationmark")
                }
            } description: {
                Text(L10n.noCardsDescription)
            }
        } else {
            ContentUnavailableView {
                Label {
                    Text(L10n.cardsNotFetchedTitle)
                } icon: {
                    Image(systemName: "wallet.pass")
                }
            } description: {
                Text(L10n.cardsNotFetchedDescription)
            }
        }
    }

    private var cardActionsTitle: String {
        String(
            localized: LocalizedStringResource(
                "dialog.cardActions.title",
                locale: Locale(identifier: languageIdentifier)
            )
        )
    }

    private var cardListTitle: String {
        String(
            localized: LocalizedStringResource(
                "cards.title",
                locale: Locale(identifier: languageIdentifier)
            )
        )
    }

    private func cardTile(_ card: Card) -> some View {
        Button {
            model.selectCard(card)
            isCardActionPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                LocalImageView(url: model.currentArtworkURL(for: card))
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 170)
                Text(card.title)
                    .font(.headline)
                    .lineLimit(1)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        model.selectedCardID == card.id
                            ? Color.accentColor
                            : Color.clear,
                        lineWidth: 3
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func userFacingText(_ text: UserFacingText?) -> some View {
        switch text {
        case let .localized(resource):
            Text(resource)
        case let .verbatim(value):
            Text(verbatim: value)
        case nil:
            Text(L10n.unknownError)
        }
    }

}

private enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case spanish = "es"
    case hindi = "hi"
    case arabic = "ar"
    case french = "fr"
    case korean = "ko"
    case indonesian = "id"

    var id: String { rawValue }

    var displayName: String {
        Locale(identifier: rawValue).localizedString(forIdentifier: rawValue)
            ?? rawValue
    }
}

private struct LocalImageView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = nil
            image = NSImage(contentsOf: url)
        }
    }
}
