import SwiftUI

@main
struct AirliftCardsApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("appLanguage") private var languageIdentifier = "en"

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                languageIdentifier: $languageIdentifier
            )
                .environment(\.locale, Locale(identifier: languageIdentifier))
                .environment(
                    \.layoutDirection,
                    languageIdentifier == "ar" ? .rightToLeft : .leftToRight
                )
                .frame(minWidth: 1_080, minHeight: 700)
                .task {
                    await model.refreshDevices()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
