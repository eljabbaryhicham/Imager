import CoreGraphics
import Foundation
import Observation

public enum ResultSortOption: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case largest
    case smallest
    case title

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .relevance: return "Relevance"
        case .largest: return "Largest first"
        case .smallest: return "Smallest first"
        case .title: return "Title A–Z"
        }
    }

    public func sort(_ results: [ImageResult]) -> [ImageResult] {
        switch self {
        case .relevance:
            return results
        case .largest:
            return results.sorted {
                switch (Self.area($0), Self.area($1)) {
                case (let a?, let b?): return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
        case .smallest:
            return results.sorted {
                switch (Self.area($0), Self.area($1)) {
                case (let a?, let b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
        case .title:
            return results.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private static func area(_ result: ImageResult) -> Double? {
        guard let width = result.width, let height = result.height else { return nil }
        return Double(width) * Double(height)
    }
}

public enum GridDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    public var minimumWidth: CGFloat {
        switch self {
        case .comfortable: return 280
        case .compact: return 210
        }
    }

    public var tileHeight: CGFloat {
        switch self {
        case .comfortable: return 270
        case .compact: return 200
        }
    }
}

@MainActor
@Observable
public final class SearchViewModel {
    public var query: String = ""
    public var selectedProviderID: String = ""
    public var quality: QualityFilter = .any
    public var format: FormatFilter = .any
    public var searchAsYouType = true
    public var sort: ResultSortOption = .relevance {
        didSet { storage.set(sort.rawValue, forKey: Self.sortKey) }
    }
    public var gridDensity: GridDensity = .comfortable {
        didSet { storage.set(gridDensity.rawValue, forKey: Self.densityKey) }
    }

    public private(set) var recentSearches: [String] = []
    public private(set) var savedSearches: [String] = []

    public private(set) var results: [ImageResult] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var hasMore = true
    public private(set) var hasSearched = false
    public private(set) var resultCountText = ""

    private var providers: [any ImageSearchProvider]
    private var currentQuery = ""
    private var currentPage = 1
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let storage: UserDefaults
    private static let recentKey = "Imager.recentSearches"
    private static let savedKey = "Imager.savedSearches"
    private static let liveKey = "Imager.searchAsYouType"
    private static let sortKey = "Imager.resultSort"
    private static let densityKey = "Imager.gridDensity"
    private static let maxRecentSearches = 8
    private static let maxSavedSearches = 20

    public var providerOptions: [(id: String, name: String)] {
        providers.map { ($0.id, $0.displayName) }
    }

    public var sortedResults: [ImageResult] {
        sort.sort(results)
    }

    public var selectedProvider: (any ImageSearchProvider)? {
        providers.first { $0.id == selectedProviderID }
    }

    public init(providers: [any ImageSearchProvider], storage: UserDefaults = .standard) {
        self.providers = providers
        self.storage = storage
        self.recentSearches = Self.loadQueries(storage.stringArray(forKey: Self.recentKey), limit: Self.maxRecentSearches)
        self.savedSearches = Self.loadQueries(storage.stringArray(forKey: Self.savedKey), limit: Self.maxSavedSearches)
        if storage.object(forKey: Self.liveKey) != nil {
            self.searchAsYouType = storage.bool(forKey: Self.liveKey)
        }
        if let rawSort = storage.string(forKey: Self.sortKey),
           let savedSort = ResultSortOption(rawValue: rawSort) {
            self.sort = savedSort
        }
        if let rawDensity = storage.string(forKey: Self.densityKey),
           let savedDensity = GridDensity(rawValue: rawDensity) {
            self.gridDensity = savedDensity
        }
        if let first = providers.first {
            self.selectedProviderID = first.id
        }
    }

    public func refreshProviders(providers: [any ImageSearchProvider]) {
        self.providers = providers
        if selectedProvider == nil, let first = providers.first {
            selectedProviderID = first.id
        }
    }

    public func setSearchAsYouType(_ enabled: Bool) {
        searchAsYouType = enabled
        storage.set(enabled, forKey: Self.liveKey)
        if !enabled {
            debounceTask?.cancel()
        }
    }

    public func queryDidChange() {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask?.cancel()
            results = []
            hasSearched = false
            errorMessage = nil
            hasMore = true
            resultCountText = ""
            return
        }
        guard searchAsYouType else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.performSearch()
        }
    }

    public func performSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentQuery = trimmed
        recordRecentSearch(trimmed)
        searchTask = Task { [weak self] in
            await self?.runSearch(page: 1, replacing: true)
        }
    }

    public func providerChanged() {
        // Switching sources should refresh the same query/filters rather than
        // leaving results from the previously selected provider on screen.
        guard hasSearched, !currentQuery.isEmpty else { return }
        query = currentQuery
        performSearch()
    }

    public func resetFilters() {
        quality = .any
        format = .any
        filtersChanged()
    }

    public func reuseSavedSearch(_ savedQuery: String) {
        let trimmed = savedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        performSearch()
    }

    public func saveCurrentQuery() {
        saveSearch(query)
    }

    public func saveSearch(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedSearches = Self.movingToFront(trimmed, in: savedSearches, limit: Self.maxSavedSearches)
        storage.set(savedSearches, forKey: Self.savedKey)
    }

    public func removeSavedSearch(_ value: String) {
        savedSearches.removeAll { $0.compare(value, options: .caseInsensitive) == .orderedSame }
        storage.set(savedSearches, forKey: Self.savedKey)
    }

    public func clearSavedSearches() {
        savedSearches = []
        storage.set(savedSearches, forKey: Self.savedKey)
    }

    public func removeRecentSearch(_ value: String) {
        recentSearches.removeAll { $0.compare(value, options: .caseInsensitive) == .orderedSame }
        storage.set(recentSearches, forKey: Self.recentKey)
    }

    public func clearRecentSearches() {
        recentSearches = []
        storage.set(recentSearches, forKey: Self.recentKey)
    }

    private func recordRecentSearch(_ value: String) {
        recentSearches = Self.movingToFront(value, in: recentSearches, limit: Self.maxRecentSearches)
        storage.set(recentSearches, forKey: Self.recentKey)
    }

    private static func loadQueries(_ values: [String]?, limit: Int) -> [String] {
        var cleaned: [String] = []
        for value in values ?? [] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !cleaned.contains(where: { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
                cleaned.append(trimmed)
            }
            if cleaned.count == limit { break }
        }
        return cleaned
    }

    private static func movingToFront(_ value: String, in values: [String], limit: Int) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return values }
        var next = values.filter { $0.compare(trimmed, options: .caseInsensitive) != .orderedSame }
        next.insert(trimmed, at: 0)
        return Array(next.prefix(limit))
    }

    public func loadMore() {
        guard !isLoadingMore, !isLoading, hasMore else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == currentQuery else { return }
        searchTask = Task { [weak self] in
            await self?.runSearch(page: (self?.currentPage ?? 1) + 1, replacing: false)
        }
    }

    public func filtersChanged() {
        guard hasSearched else { return }
        performSearch()
    }

    private func runSearch(page: Int, replacing: Bool) async {
        guard let provider = selectedProvider else {
            errorMessage = "No image source is configured. Add a provider in Settings."
            return
        }
        if replacing { isLoading = true } else { isLoadingMore = true }
        errorMessage = nil
        defer {
            isLoading = false
            isLoadingMore = false
        }

        let filters = SearchFilters(quality: quality, format: format)
        do {
            let fetched = try await provider.search(query: currentQuery, filters: filters, page: page)
            guard !Task.isCancelled else { return }
            if replacing {
                results = fetched
            } else {
                var seenIDs = Set(results.map(\.id))
                results += fetched.filter { seenIDs.insert($0.id).inserted }
            }
            currentPage = page
            hasMore = !fetched.isEmpty
            hasSearched = true
            resultCountText = "\(results.count) image\(results.count == 1 ? "" : "s")"
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            if replacing {
                errorMessage = error.localizedDescription
                results = []
                hasSearched = true
                resultCountText = ""
            }
        }
    }
}