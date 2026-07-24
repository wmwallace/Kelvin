import Foundation

/// Loading and saving recipe sidecars. All disk reads clamp on decode (see Recipe).
public enum RecipeIO {
    public static func load(from url: URL) throws -> Recipe {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: data)
    }

    public static func data(for recipe: Recipe) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(recipe)
    }

    public static func save(_ recipe: Recipe, to url: URL) throws {
        try data(for: recipe).write(to: url)
    }
}
