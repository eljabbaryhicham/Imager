import SwiftUI
import AppKit
import ImagerCore

struct FloatingContentView: View {
    let settings: SettingsStore
    @Bindable var search: SearchViewModel
    @Bindable var favorites: FavoritesStore
    let glide: PanelGlide
    let onHide: () -> Void
    let onShowSettings: () -> Void

    @State private var tab: ContentTab = .search
    @State private var isExpanded = false
    /// Expanded height, fitted to the room below the panel so growth never
    /// pushes the bottom off-screen (which would make macOS shove the whole
    /// window and visibly move the search row).
    @State private var expandedHeight: CGFloat = 740
    @State private var showHistory = false
    @FocusState private var searchFocused: Bool

    enum ContentTab: String {
        case search = "Search"
        case favorites = "Favorites"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, isExpanded ? 10 : 0)

            if isExpanded {
                Divider()
                    .overlay(Color.white.opacity(0.06))
                controlsRow
                Divider()
                    .overlay(Color.white.opacity(0.06))
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .windowDragExcluded()
            }
        }
        .padding(20)
        .frame(minWidth: 1100, minHeight: isExpanded ? expandedHeight : 90)
        .background(Theme.panelMaterial)
        .overlay(alignment: .top) {
            // Thin "light catch" along the top edge to simulate light hitting glass.
            LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1)
        }
        .overlay {
            // Subtle neon rim so the palette pops against the desktop.
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .themeAware(settings.theme)
        .windowDraggable()
        .resizeGrip(active: isExpanded)
        .onExitCommand { onHide() }
        .onChange(of: search.query) {
            let expand = !search.query.isEmpty
            if expand,
               let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is FloatingPanel }),
               let screen = window.screen ?? NSScreen.main {
                // Grow only as far as the screen allows below the current top
                // edge: the row stays exactly where it is and the bottom lands
                // on (or above) the screen edge instead of overflowing.
                let room = window.frame.maxY - screen.visibleFrame.minY - 8
                expandedHeight = min(740, max(320, room))
            }
            isExpanded = expand
        }
        .onChange(of: isExpanded) { _, _ in
            // Anchor the current top edge; the resize observer holds it on
            // every step of SwiftUI's animated resize, so the panel glides
            // open downward while the search row stays fixed. Single writer
            // (SwiftUI owns the size, the observer only shifts origin), so no
            // intermediate frame ever flashes.
            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is FloatingPanel }) {
                glide.anchorTop = window.frame.maxY
            }
            glide.corrections = 0
            glide.pinUntil = Date().addingTimeInterval(0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [glide] in
                let frame = (NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is FloatingPanel }))?.frame ?? .zero
                ImagerLog.log("expand glide corrections=\(glide.corrections) finalTop=\(Int(frame.maxY)) anchorTop=\(Int(glide.anchorTop)) frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width))x\(Int(frame.size.height))")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .search:
            ResultsGridView(search: search, favorites: favorites, settings: settings)
        case .favorites:
            FavoritesView(favorites: favorites, settings: settings)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .shadow(color: Theme.accentGlow, radius: 8)
                .accessibilityLabel("Imager")
                .help("Imager")

            searchCapsule

            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .glassSurface(cornerRadius: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .windowDragExcluded()

            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .glassSurface(cornerRadius: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Minimize to the menu bar")
            .windowDragExcluded()
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: HeaderPositionKey.self,
                    value: geo.frame(in: .global).minY
                )
            }
        }
        .onPreferenceChange(HeaderPositionKey.self) { headerY in
            let windowY = NSApp.windows.first(where: { $0 is FloatingPanel })?.frame.origin.y ?? 0
            Self.reportHeaderPosition(windowY: windowY, headerY: headerY)
        }
    }

    private static var lastHeaderY: CGFloat?
    private static var lastWindowY: CGFloat?

    /// Temporary diagnostic: records any real displacement of the search row
    /// (and whether the window itself moved with it).
    private static func reportHeaderPosition(windowY: CGFloat, headerY: CGFloat) {
        if let lastH = lastHeaderY, let lastW = lastWindowY,
           abs(headerY - lastH) > 0.5 || abs(windowY - lastW) > 0.5 {
            ImagerLog.log("header moved headerY=\(String(format: "%.1f", lastH))->\(String(format: "%.1f", headerY)) windowY=\(String(format: "%.1f", lastW))->\(String(format: "%.1f", windowY))")
        }
        lastHeaderY = headerY
        lastWindowY = windowY
    }

    /// Search dominates the header; the provider menu docks to its trailing
    /// edge inside the same capsule, and the capsule glows while editing.
    private var searchCapsule: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                TextField("", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($searchFocused)
                    .onSubmit { search.performSearch() }
                    .onChange(of: search.query) { search.queryDidChange() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if search.query.isEmpty {
                            Text("search images...")
                                .font(.body)
                                .foregroundStyle(Theme.accent)
                                .allowsHitTesting(false)
                        }
                    }
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Recent and saved searches")
            }
            .padding(.leading, 16)

            Divider()
                .frame(height: 32)
                .overlay(Theme.surfaceBorder)
                .padding(.horizontal, 10)

            TintedMenu(
                options: search.providerOptions.map { ($0.id, $0.name) },
                selection: $search.selectedProviderID,
                help: "Image source",
                width: 150
            )
            .padding(.trailing, 8)
            .onChange(of: search.selectedProviderID) { search.providerChanged() }
        }
        .padding(.vertical, 11)
        .foregroundStyle(Theme.textPrimary)
        .glassSurface(cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accentBorder : .clear, lineWidth: 1.5)
        }
        .popover(isPresented: $showHistory) {
            searchHistoryPopover
        }
        .windowDragExcluded()
    }

    private var searchHistoryPopover: some View {
        let liveBinding = Binding(
            get: { search.searchAsYouType },
            set: { search.setSearchAsYouType($0) }
        )
        let currentQuery = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSaveCurrent = !currentQuery.isEmpty && !search.savedSearches.contains(where: {
            $0.compare(currentQuery, options: .caseInsensitive) == .orderedSame
        })

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Search history")
                    .font(.title3)
                Spacer()
                Button("Done") { showHistory = false }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
            }

            Toggle("Search as you type", isOn: liveBinding)
                .tint(Theme.accent)
                .font(.callout)
                .help("When off, searches run only after you press Return.")

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent")
                        .font(.headline)
                    Spacer()
                    if !search.recentSearches.isEmpty {
                        Button("Clear") { search.clearRecentSearches() }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if search.recentSearches.isEmpty {
                    Text("No recent searches yet.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(search.recentSearches, id: \.self) { item in
                        HStack {
                            Text(item)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                search.removeRecentSearch(item)
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove this recent search")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            search.query = item
                            search.performSearch()
                            showHistory = false
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Saved")
                        .font(.headline)
                    Spacer()
                    Button("Save current") { search.saveCurrentQuery() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(canSaveCurrent ? Theme.accent : Theme.textSecondary)
                        .disabled(!canSaveCurrent)
                    if !search.savedSearches.isEmpty {
                        Button("Clear") { search.clearSavedSearches() }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if search.savedSearches.isEmpty {
                    Text("Save a search to rerun it with one click.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(search.savedSearches, id: \.self) { item in
                        HStack {
                            Text(item)
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                search.removeSavedSearch(item)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove this saved search")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            search.reuseSavedSearch(item)
                            showHistory = false
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.popoverMaterial)
    }

    private var controlsRow: some View {
        HStack(spacing: 14) {
            TintedMenu(
                options: QualityFilter.allCases.map { ($0, $0.label) },
                selection: $search.quality,
                help: "Size",
                width: 150
            )
            .onChange(of: search.quality) { search.filtersChanged() }

            TintedMenu(
                options: FormatFilter.allCases.map { ($0, $0.label) },
                selection: $search.format,
                help: "Format",
                width: 120
            )
            .onChange(of: search.format) { search.filtersChanged() }

            if search.quality != .any || search.format != .any {
                Button("Reset") { search.resetFilters() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .help("Reset size and format filters")
                    .windowDragExcluded()
            }

            Divider()
                .frame(height: 28)
                .overlay(Theme.surfaceBorder)

            Picker("View", selection: $tab) {
                Text("Search").tag(ContentTab.search)
                Text("Favorites").tag(ContentTab.favorites)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .layoutPriority(1)
            .windowDragExcluded()

            if search.hasSearched, !search.resultCountText.isEmpty {
                Text(search.resultCountText)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 80, maxWidth: 250, alignment: .leading)
                    .layoutPriority(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Text(settings.saveDirectoryURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Save folder: \(settings.saveDirectoryURL.path)")
            }
            .frame(maxWidth: 260, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.textSecondary.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

}

/// Reports the search row's on-screen vertical position for diagnostics.
private struct HeaderPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Compact dropdown that keeps the app's green accent. macOS's own menus
/// always highlight with the system blue, so options render inside an
/// app-tinted popover instead of an NSMenu — fully themed to Imager.
private struct TintedMenu<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var help = ""
    var width: CGFloat = 88

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.leading, 13)
            .padding(.trailing, 10)
            .frame(width: width, height: 38)
            .background(Theme.textSecondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            optionsList
        }
        .windowDragExcluded()
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    private var optionsList: some View {
        VStack(spacing: 3) {
            ForEach(options, id: \.value) { option in
                HStack(spacing: 12) {
                    Text(option.label)
                        .font(.body)
                        .foregroundStyle(option.value == selection ? Color.white : Theme.textPrimary)
                    Spacer()
                    if option.value == selection {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    option.value == selection ? Theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = option.value
                    isOpen = false
                }
            }
        }
        .padding(10)
        .frame(width: max(width + 28, 200))
        .background(Theme.popoverMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .preferredColorScheme(.dark)
    }
}
