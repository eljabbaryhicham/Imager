import Foundation
import Observation

@MainActor
@Observable
public final class FavoritesStore {
    public struct Item: Identifiable, Codable, Hashable {
        public let image: ImageResult
        public let addedAt: Date

        public var id: String { image.id }

        public init(image: ImageResult, addedAt: Date) {
            self.image = image
            self.addedAt = addedAt
        }
    }

    public private(set) var items: [Item] = []

    private let fileURL: URL

    public init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Imager", isDirectory: true)
        self.fileURL = support.appendingPathComponent("favorites.json")
        load()
    }

    public var isEmpty: Bool { items.isEmpty }

    public func isFavorite(_ result: ImageResult) -> Bool {
        items.contains { $0.image.id == result.id }
    }

    public func toggle(_ result: ImageResult) {
        if let index = items.firstIndex(where: { $0.image.id == result.id }) {
            items.remove(at: index)
        } else {
            items.insert(Item(image: result, addedAt: Date()), at: 0)
        }
        save()
    }

    public func remove(id: String) {
        items.removeAll { $0.image.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}