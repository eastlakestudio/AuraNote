import Foundation

struct HotwordCategory: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var words: [String]
    
    var wordsString: String {
        words.joined(separator: " ")
    }
}

@MainActor
@Observable
final class HotwordPresetsManager {
    static let shared = HotwordPresetsManager()
    
    var categories: [HotwordCategory] = []
    
    private let jsonURL: URL
    
    private init() {
        let dataDir = SettingsManager.shared.dataDirectory
        jsonURL = dataDir.appendingPathComponent("hotword_presets.json")
        load()
    }
    
    func load() {
        do {
            if !FileManager.default.fileExists(atPath: jsonURL.path) {
                if let bundleURL = Bundle.main.url(forResource: "hotword_presets", withExtension: "json") {
                    try FileManager.default.copyItem(at: bundleURL, to: jsonURL)
                }
            }
            
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                let data = try Data(contentsOf: jsonURL)
                let decoded = try JSONDecoder().decode([HotwordCategory].self, from: data)
                self.categories = decoded
            } else {
                // No default fallback as requested by user
                self.categories = []
                save()
            }
        } catch {
            print("Failed to load hotword presets: \(error)")
        }
    }
    
    func save() {
        do {
            let data = try JSONEncoder().encode(categories)
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            print("Failed to save hotword presets: \(error)")
        }
    }
    
    func getWords(for ids: [String]) -> String {
        categories
            .filter { ids.contains($0.id) }
            .map { $0.wordsString }
            .joined(separator: " ")
    }
}
