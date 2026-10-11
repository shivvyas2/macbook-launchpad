import SwiftUI

struct LaunchpadView: View {
    @Bindable var store: LaunchpadStore
    @FocusState private var searchFocused: Bool
    @Namespace private var morph
    private var prefs: Preferences { .shared }

    var body: some View {
        GeometryReader { geo in
            let layout = GridLayout(size: geo.size, insets: store.screenInsets, columns: store.gridColumns,
                                    rows: store.gridRows, maxIconSize: CGFloat(prefs.iconSize))
            ZStack {
                // The window itself is frosted glass over the screen. Tapping empty space closes the launcher.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Like the original: a click on empty space first ends jiggle mode, then closes.
                        if store.isEditing { withAnimation(.spring(duration: 0.3)) { store.isEditing = false } }
                        else { store.dismiss?() }
                    }
                    .contextMenu {
                        Button("New Folder") { withAnimation(.spring(duration: 0.35)) { store.createFolder() } }
                        Button("Organize Apps…") { withAnimation(.spring(duration: 0.35)) { store.showingOrganizer = true } }
                        Divider()
                        Button("Settings…") { store.openSettings?() }
                    }

                VStack(spacing: 0) {
                    SearchField(text: $store.query, focused: $searchFocused)
                        .padding(.top, layout.topInset)
                        .frame(height: layout.topInset + 44, alignment: .bottom)

                    Group {
                        if store.query.isEmpty {
                            PagedGrid(store: store, layout: layout, width: geo.size.width)
                        } else {
                            SearchResults(store: store, layout: layout)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    PageDots(store: store)
                        .opacity(store.query.isEmpty && store.pageCount > 1 ? 1 : 0)
                        .frame(height: layout.bottomInset)
                }
                .scaleEffect(store.isShown ? (store.openFolderID != nil ? 0.96 : 1) : 1.06)
                .opacity(store.isShown ? 1 : 0)
                // Blur can't be captured offscreen, so screenshots fade the grid behind overlays instead.
                .opacity(Screenshots.isRendering && (store.openFolderID != nil || store.showingOrganizer) ? 0.03 : 1)

                // Behind folders and the organizer: a material layer that the window server blurs. Fading its
                // opacity is far cheaper than animating a SwiftUI blur over the whole grid.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(!Screenshots.isRendering && (store.openFolderID != nil || store.showingOrganizer) ? 1 : 0)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                if let folder = store.openFolder {
                    // The panel's glass and icons morph out of the folder icon (matched geometry);
                    // everything else simply fades.
                    FolderOverlay(store: store, folder: folder, layout: layout)
                        .transition(.opacity)
                        .zIndex(2)
                }

                if store.showingOrganizer {
                    OrganizeOverlay(store: store)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .zIndex(3)
                }

                if store.undoEntries != nil && !store.showingOrganizer {
                    UndoToast(store: store)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, layout.bottomInset + 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(4)
                }

                HStack(spacing: 12) {
                    CircleButton(symbol: "folder.badge.plus", help: "New Folder") {
                        withAnimation(.spring(duration: 0.35)) { store.createFolder() }
                    }
                    CircleButton(symbol: "wand.and.sparkles", help: "Organize Apps") {
                        withAnimation(.spring(duration: 0.35)) { store.showingOrganizer = true }
                    }
                    CircleButton(symbol: "gearshape.fill", help: "Settings") { store.openSettings?() }
                }
                // Top-right, centered on the search bar's row (field is 34pt tall at the bottom of a 44pt band).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 28)
                .padding(.top, layout.topInset + 44 - 17 - 20)
                .opacity(store.isShown && store.openFolderID == nil && !store.showingOrganizer ? 1 : 0)

                if let drag = store.drag {
                    DragGhost(store: store, drag: drag)
                        .zIndex(10)
                }
            }
            .coordinateSpace(.named(launchpadSpace))
            .environment(\.launchpadNamespace, morph)
            .onAppear { store.viewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in store.viewportWidth = width }
        }
        .ignoresSafeArea()
        .onChange(of: store.isShown) { _, shown in if shown { searchFocused = true } }
        .onChange(of: store.openFolderID) { _, id in if id == nil { searchFocused = true } }
        .onAppear { searchFocused = true }
    }
}

/// Grid geometry derived from the screen size and preferences.
struct GridLayout {
    let columns: Int
    let rows: Int
    let iconSize: CGFloat
    let cell: CGSize
    let gridSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    var labelSize: CGFloat { min(13.5, max(10.5, iconSize * 0.155)) }

    init(size: CGSize, insets: EdgeInsets, columns: Int, rows: Int, maxIconSize: CGFloat) {
        self.columns = columns
        self.rows = rows
        let area = Self.gridArea(size: size, insets: insets)
        topInset = area.top
        bottomInset = area.bottom
        gridSize = area.size
        cell = CGSize(width: area.size.width / CGFloat(columns), height: area.size.height / CGFloat(rows))
        // Big displays get bigger icons rather than a denser grid.
        let screenScale = min(max(area.size.height / 730, 1), 1.4)
        iconSize = max(32, min(maxIconSize * screenScale, cell.width * 0.66, cell.height * 0.6))
    }

    /// The space the icon grid gets after the search bar, page dots and screen edges.
    private static func gridArea(size: CGSize, insets: EdgeInsets) -> (size: CGSize, top: CGFloat, bottom: CGFloat) {
        let top = insets.top + max(28, size.height * 0.045)
        let bottom = insets.bottom + 56
        let sidePadding = min(size.width * 0.12, 240)
        let height = size.height - top - 44 - bottom - 30
        return (CGSize(width: max(200, size.width - sidePadding * 2), height: max(150, height)), top, bottom)
    }

    /// Columns and rows for a screen: the Settings values, or a fit to the screen when "Fit grid to screen" is on.
    @MainActor static func fittingGrid(size: CGSize, insets: EdgeInsets) -> (columns: Int, rows: Int) {
        let prefs = Preferences.shared
        guard prefs.autoGrid else { return (prefs.columns, prefs.rows) }
        let area = gridArea(size: size, insets: insets)
        // Aim for roughly the classic 7 x 5 Launchpad; small screens drop columns/rows, big ones add a little.
        let columns = Int((area.size.width / 165).rounded())
        let rows = Int((area.size.height / 150).rounded())
        return (min(max(columns, 4), 8), min(max(rows, 3), 6))
    }
}

// MARK: - Search

struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .font(.system(size: 15))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 290, height: 34)
        .launchpadGlass(.regular.tint(.white.opacity(0.08)), in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}

struct SearchResults: View {
    let store: LaunchpadStore
    let layout: GridLayout

    var body: some View {
        let results = store.searchResults
        if results.isEmpty {
            Text("No Results")
                .font(.title2.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cell.width), spacing: 0), count: layout.columns), spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                        AppCell(app: app, iconSize: layout.iconSize, highlighted: index == store.selection)
                            .frame(width: layout.cell.width, height: layout.cell.height)
                            .contentShape(Rectangle())
                            .onTapGesture { store.launch(app) }
                            .onHover { if $0 { store.selection = index } }
                            .contextMenu { AppMenu(store: store, app: app, folderID: nil) }
                    }
                }
                .frame(width: layout.gridSize.width)
                .padding(.top, 30)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Paged grid

struct PagedGrid: View {
    let store: LaunchpadStore
    let layout: GridLayout
    let width: CGFloat

    var body: some View {
        PageStrip(store: store, layout: layout, width: width)
            .offset(x: -CGFloat(store.currentPage) * width + store.swipeOffset)
            .frame(width: width, alignment: .leading)
            .padding(.top, 30)
    }
}

/// All pages side by side. Split out from PagedGrid so swipe offsets don't re-render the icons.
private struct PageStrip: View {
    let store: LaunchpadStore
    let layout: GridLayout
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<store.pageCount, id: \.self) { page in
                PageView(store: store, entries: Array(store.page(page)), layout: layout)
                    .frame(width: width)
            }
        }
    }
}

struct PageView: View {
    let store: LaunchpadStore
    let entries: [LayoutEntry]
    let layout: GridLayout

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<layout.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<layout.columns, id: \.self) { col in
                        let i = row * layout.columns + col
                        if i < entries.count {
                            EntryCell(store: store, entry: entries[i], layout: layout)
                        } else {
                            Color.clear.frame(width: layout.cell.width, height: layout.cell.height)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct EntryCell: View {
    let store: LaunchpadStore
    let entry: LayoutEntry
    let layout: GridLayout

    var body: some View {
        let isTarget = store.folderTargetID == entry.id
        let isDragged = store.drag?.id == entry.id
        content(isTarget: isTarget)
            .wiggle(store.isEditing && !isDragged, seed: entry.id)
            .frame(width: layout.cell.width, height: layout.cell.height)
            .contentShape(Rectangle())
            .opacity(isDragged ? 0 : 1) // the floating copy stands in while dragging
            .onTapGesture { if !store.isEditing { open() } }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                withAnimation(.spring(duration: 0.3)) { store.isEditing = true }
            })
            .arrangeGesture(store, id: entry.id, source: .grid, iconSize: layout.iconSize)
            .reportsFrame(LaunchpadStore.frameKey(entry.id, inFolder: false), to: store)
            .contextMenu { menu }
    }

    @ViewBuilder
    private func content(isTarget: Bool) -> some View {
        switch entry {
        case .app(let path):
            if let app = store.apps[path] {
                AppCell(app: app, iconSize: layout.iconSize, highlighted: false, mergeTarget: isTarget)
            }
        case .folder(let folder):
            FolderCell(store: store, folder: folder, iconSize: layout.iconSize, highlighted: isTarget,
                       isOpen: store.openFolderID == folder.id)
        }
    }

    private func open() {
        switch entry {
        case .app(let path):
            if let app = store.apps[path] { store.launch(app) }
        case .folder(let folder):
            withAnimation(.spring(duration: 0.4, bounce: 0.12)) { store.openFolderID = folder.id }
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch entry {
        case .app(let path):
            if let app = store.apps[path] { AppMenu(store: store, app: app, folderID: nil) }
        case .folder(let folder):
            Button("Open") { open() }
            Button("Ungroup") { withAnimation(.spring(duration: 0.3)) { store.ungroup(folder.id) } }
        }
    }
}

struct AppMenu: View {
    let store: LaunchpadStore
    let app: AppInfo
    let folderID: UUID?

    var body: some View {
        Button("Open") { store.launch(app) }
        Button("Show in Finder") { store.showInFinder(app) }
        Button("Hide from Launchpad") { withAnimation(.spring(duration: 0.3)) { store.hide(app) } }
        if folderID == nil && store.index(of: app.id) != nil {
            Button("New Folder with “\(app.name)”") {
                withAnimation(.spring(duration: 0.35)) { store.createFolder(with: app.id) }
            }
        }
        if let folderID {
            Divider()
            Button("Remove from Folder") {
                withAnimation(.spring(duration: 0.3)) { store.removeFromFolder(folderID, app: app.id) }
            }
        }
    }
}

// MARK: - Cells

struct AppCell: View {
    let app: AppInfo
    let iconSize: CGFloat
    var highlighted = false
    var mergeTarget = false
    var matchID: String? = nil
    @State private var hovering = false
    @Environment(\.launchpadNamespace) private var morph

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if mergeTarget {
                    // Same shape the new folder will have, so the icon sits concentrically inside it.
                    Color.clear
                        .frame(width: iconSize, height: iconSize)
                        .launchpadGlass(.regular, in: .rect(cornerRadius: iconSize * 0.24, style: .continuous))
                }
                Image(nsImage: IconCache.shared.icon(for: app.id))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .matched(matchID, in: morph)
                    .scaleEffect(mergeTarget ? 0.7 : (hovering ? 1.05 : 1))
            }
            .frame(width: iconSize * 1.15, height: iconSize * 1.15)
            Text(app.name)
                .font(.system(size: min(13.5, max(10.5, iconSize * 0.155)), weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: iconSize * 1.6)
        }
        .padding(6)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.18))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .animation(.spring(duration: 0.25), value: mergeTarget)
    }
}

struct FolderIcon: View {
    let store: LaunchpadStore
    let folder: Folder
    let size: CGFloat
    /// Whether this copy takes part in the open/close morph (the drag ghost doesn't).
    var matched = true
    @Environment(\.launchpadNamespace) private var morph

    var body: some View {
        // Concentric geometry: each tile's corner radius is the folder's radius minus the padding,
        // so the inner corners run parallel to the outer ones.
        // Solve for the padding p that makes both hold:
        //   tileRadius = outerRadius - p          (concentric corners)
        //   tileRadius = k * tile                 (tiles keep an app-icon squircle shape)
        //   tile = (side - 2p - 2 * gap) / 3
        let side = size * 0.86
        let outerRadius = side * 0.24
        let gap = side * 0.045
        let k: CGFloat = 0.33
        let padding = (outerRadius - k * (side - 2 * gap) / 3) / (1 - 2 * k / 3)
        let tile = (side - padding * 2 - gap * 2) / 3
        let tileRadius = outerRadius - padding
        let apps = Array(folder.apps.prefix(9))

        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { col in
                        let i = row * 3 + col
                        if i < apps.count {
                            MiniIcon(path: apps[i], size: tile, radius: tileRadius)
                                .matched(matched ? "app-" + apps[i] : nil, in: morph)
                        } else {
                            Color.clear.frame(width: tile, height: tile)
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side) // grid fills from the top-left, like the original
        .background {
            Color.clear
                .matched(matched ? "folder-" + folder.id.uuidString : nil, in: morph)
                .launchpadGlass(.regular, in: .rect(cornerRadius: outerRadius, style: .continuous))
        }
        .frame(width: size, height: size)
    }
}

/// An app icon with its built-in transparent margin trimmed, clipped to a given corner radius.
struct MiniIcon: View {
    let path: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .interpolation(.high)
            // macOS icons draw their body in 824 of 1024 points; scale that body to fill the tile.
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}

struct FolderCell: View {
    let store: LaunchpadStore
    let folder: Folder
    let iconSize: CGFloat
    var highlighted = false
    var isOpen = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 7) {
            Group {
                // While open, the icon lives on as the panel; leave its slot empty.
                if isOpen {
                    Color.clear.frame(width: iconSize, height: iconSize)
                } else {
                    FolderIcon(store: store, folder: folder, size: iconSize)
                }
            }
            .scaleEffect(highlighted ? 1.15 : (hovering ? 1.05 : 1))
            .frame(width: iconSize * 1.15, height: iconSize * 1.15)
            Text(folder.name)
                .font(.system(size: min(13.5, max(10.5, iconSize * 0.155)), weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: iconSize * 1.6)
        }
        .padding(6)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .animation(.spring(duration: 0.25), value: highlighted)
    }
}

// MARK: - Folder overlay

struct FolderOverlay: View {
    let store: LaunchpadStore
    let folder: Folder
    let layout: GridLayout
    @FocusState private var nameFocused: Bool
    @State private var addingApps = false
    @Environment(\.launchpadNamespace) private var morph

    var body: some View {
        // Square-ish rows, at least 3 across: 7 apps → 3 + 3 + 1, 16 → 4 x 4, 30 → 6 x 5.
        let count = max(folder.apps.count, 1)
        let maxColumns = max(3, min(6, layout.columns - 1))
        let columns = min(count, min(maxColumns, max(3, Int(Double(count).squareRoot().rounded(.up)))))
        let cell = CGSize(width: min(layout.cell.width, 150), height: min(layout.cell.height, 150))
        let totalRows = (folder.apps.count + columns - 1) / columns
        let visibleRows = max(1, min(totalRows, Int(layout.gridSize.height * 0.7 / cell.height)))
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(duration: 0.34, bounce: 0.05)) { store.closeFolder() } }

            VStack(spacing: 18) {
                TextField("Folder Name", text: Binding(
                    get: { folder.name },
                    set: { name in store.updateFolder(folder.id) { $0.name = name } }
                ))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .focused($nameFocused)
                .frame(maxWidth: 360)
                .overlay(alignment: .trailing) {
                    Button { withAnimation(.spring(duration: 0.3)) { addingApps.toggle() } } label: {
                        Image(systemName: addingApps ? "checkmark" : "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .launchpadGlass(.regular.interactive(), in: .circle)
                    .help(addingApps ? "Done Adding" : "Add Apps")
                    .offset(x: 44)
                }

                if addingApps {
                    AddAppsPicker(store: store, folderID: folder.id) {
                        withAnimation(.spring(duration: 0.3)) { addingApps = false }
                    }
                    .transition(.opacity)
                } else if folder.apps.isEmpty {
                    Text("Drag apps here, or click + to add some.")
                        .foregroundStyle(.secondary)
                        .frame(height: 80)
                }

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell.width), spacing: 0), count: columns), spacing: 0) {
                        ForEach(folder.apps, id: \.self) { path in
                            if let app = store.apps[path] {
                                let size = min(layout.iconSize, cell.width * 0.7)
                                AppCell(app: app, iconSize: size, matchID: "app-" + path)
                                    .wiggle(store.isEditing && store.drag?.id != path, seed: path)
                                    .frame(width: cell.width, height: cell.height)
                                    .contentShape(Rectangle())
                                    .opacity(store.drag?.id == path ? 0 : 1)
                                    .onTapGesture { if !store.isEditing { store.launch(app) } }
                                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                        withAnimation(.spring(duration: 0.3)) { store.isEditing = true }
                                    })
                                    .arrangeGesture(store, id: path, source: .folder(folder.id), iconSize: size)
                                    .reportsFrame(LaunchpadStore.frameKey(path, inFolder: true), to: store)
                                    .contextMenu { AppMenu(store: store, app: app, folderID: folder.id) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(visibleRows) * cell.height)
            }
            .padding(30)
            .frame(width: min(max(CGFloat(columns) * cell.width + 60, addingApps ? 600 : 420), layout.gridSize.width + 160))
            .background {
                // Grows out of the folder icon's glass when opening, and shrinks back into it when closing.
                Color.clear
                    .matched("folder-" + folder.id.uuidString, in: morph)
                    .launchpadGlass(.regular, in: .rect(cornerRadius: 40, style: .continuous))
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(launchpadSpace)) } action: { store.folderPanelFrame = $0 }
            .onDisappear { store.folderPanelFrame = .zero }
            .environment(\.colorScheme, .dark)
        }
        .onChange(of: nameFocused) { _, focused in store.editingFolderName = focused }
        .onAppear {
            // A brand-new folder starts with its name selected and the app picker open.
            if folder.name == "New Folder" && folder.apps.count <= 1 {
                nameFocused = true
                addingApps = folder.apps.isEmpty
            }
        }
    }
}

// MARK: - Chrome

struct PageDots: View {
    let store: LaunchpadStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<store.pageCount, id: \.self) { page in
                Circle()
                    .fill(.white.opacity(page == store.currentPage ? 0.95 : 0.4))
                    .frame(width: 7, height: 7)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.32)) { store.goToPage(page) }
                    }
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2)
    }
}

struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .launchpadGlass(.regular.interactive(), in: .circle)
        .help(help)
    }
}

extension View {
    /// matchedGeometryEffect when both an id and a namespace are available.
    @ViewBuilder
    func matched(_ id: String?, in namespace: Namespace.ID?) -> some View {
        if let id, let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}
