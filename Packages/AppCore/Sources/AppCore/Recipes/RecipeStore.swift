import Foundation
import Observation

/// A named, saved ``ContainerRecipe``.
public struct SavedRecipe: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var saved: Date
    public var recipe: ContainerRecipe

    public init(id: UUID = UUID(), name: String, saved: Date = Date(), recipe: ContainerRecipe) {
        self.id = id
        self.name = name
        self.saved = saved
        self.recipe = recipe
    }
}

/// Saved recipes in `~/Library/Application Support/Gantry/recipes.json`.
/// A file that cannot be read is kept as is and the list starts empty,
/// so a bad file is never overwritten until the user saves again.
@MainActor
@Observable
public final class RecipeStore {
    public private(set) var recipes: [SavedRecipe] = []
    /// Set when the last load or save failed.
    public private(set) var lastError: String?

    private let fileURL: URL?

    /// The store at `fileURL`; nil uses the Application Support file.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    public static let shared = RecipeStore()

    /// `GANTRY_RECIPES_PATH` overrides the location, for tests.
    static func defaultURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["GANTRY_RECIPES_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return support.appendingPathComponent("Gantry", isDirectory: true)
            .appendingPathComponent("recipes.json", isDirectory: false)
    }

    struct FileBody: Codable {
        var version = 1
        var recipes: [SavedRecipe]
    }

    public func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            recipes = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recipes = try decoder.decode(FileBody.self, from: data).recipes
            lastError = nil
        } catch {
            recipes = []
            lastError = String(localized: "Gantry cannot read the saved recipes file.", bundle: .module)
        }
    }

    /// The trimmed name, or nil when it is empty.
    public static func cleanName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// True when a recipe with this name exists (case is ignored).
    public func contains(name: String) -> Bool {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recipes.contains { $0.name.lowercased() == key }
    }

    /// Saves `recipe` under `name`. A recipe with the same name is replaced.
    @discardableResult
    public func save(name: String, recipe: ContainerRecipe, now: Date = Date()) -> SavedRecipe? {
        guard let clean = Self.cleanName(name) else { return nil }
        let key = clean.lowercased()
        var item = SavedRecipe(name: clean, saved: now, recipe: recipe)
        if let index = recipes.firstIndex(where: { $0.name.lowercased() == key }) {
            item.id = recipes[index].id
            recipes[index] = item
        } else {
            recipes.append(item)
        }
        recipes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        write()
        return item
    }

    public func delete(id: UUID) {
        recipes.removeAll { $0.id == id }
        write()
    }

    private func write() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(FileBody(recipes: recipes)).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = String(localized: "Gantry cannot save the recipes file.", bundle: .module)
        }
    }
}
