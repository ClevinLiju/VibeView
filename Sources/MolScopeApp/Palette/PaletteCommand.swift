import SwiftUI

struct PaletteCommand: Identifiable {
    var id: String
    var title: String
    var subtitle: String? = nil
    var symbol: String
    var category: String
    var keywords: [String] = []
    var shortcut: String? = nil
    var isEnabled: Bool = true
    var perform: @MainActor () -> Void
}
