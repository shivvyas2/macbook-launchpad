import SwiftUI
import UniformTypeIdentifiers

struct LaunchpadView: View {
    @Bindable var store: LaunchpadStore
    @FocusState private var searchFocused: Bool
    private var prefs: Preferences { .shared }

    var body: some View {
        GeometryReader { geo in
            let layout = GridLayout(size: geo.size, insets: store.screenInsets, prefs: prefs)
            ZStack {
                // Blurred desktop picture, like the original Launchpad. Tapping it closes the launcher.
                WallpaperBackground(store: store)
                    .contentShape(Rectangle())
                .onTapGesture { store.dismiss?() }

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
                .scaleEffect(store.isShown ? 1 : 1.07)
                .opacity(store.isShown ? 1 : 0)
                .blur(radius: store.openFolderID != nil ? 14 : 0)

                if store.draggingID != nil && store.query.isEmpty && store.openFolderID == nil {
                    EdgeFlipZones(store: store)
                }

                if let folder = store.openFolder {
                    FolderOverlay(store: store, folder: folder, layout: layout)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .zIndex(2)
                }

                SettingsButton { store.openSettings?() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(28)
                    .opacity(store.isShown && store.openFolderID == nil ? 1 : 0)
            }
            // Catch-all so a drag released anywhere always ends cleanly.
            .onDrop(of: [.text], delegate: EndDragDelegate(store: store))
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

    @MainActor init(size: CGSize, insets: EdgeInsets, prefs: Preferences) {
        columns = prefs.columns
        rows = prefs.rows
        topInset = insets.top + max(36, size.height * 0.05)
        bottomInset = insets.bottom + 56
        let horizontalPadding = size.width * 0.14
        let available = CGSize(width: size.width - horizontalPadding * 2,
                               height: size.height - topInset - 44 - bottomInset - 30)
        cell = CGSize(width: available.width / CGFloat(columns), height: available.height / CGFloat(rows))
        gridSize = available
        iconSize = min(CGFloat(prefs.iconSize), cell.width * 0.78, cell.height * 0.68)
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
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .capsule)
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
        HStack(spacing: 0) {
            ForEach(0..<store.pageCount, id: \.self) { page in
                PageView(store: store, entries: Array(store.page(page)), layout: layout)
                    .frame(width: width)
            }
        }
        .offset(x: -CGFloat(store.currentPage) * width + store.swipeOffset)
        .frame(width: width, alignment: .leading)
        .padding(.top, 30)
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
        content(isTarget: isTarget)
            .frame(width: layout.cell.width, height: layout.cell.height)
            .contentShape(Rectangle())
            .opacity(store.draggingID == entry.id ? 0.3 : 1)
            .onTapGesture { open() }
            .onDrag {
                store.draggingID = entry.id
                store.folderTargetID = nil
                return NSItemProvider(object: entry.id as NSString)
            } preview: {
                dragPreview
            }
            .onDrop(of: [.text], delegate: GridDropDelegate(store: store, target: entry, cell: layout.cell))
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
            FolderCell(store: store, folder: folder, iconSize: layout.iconSize, highlighted: isTarget)
        }
    }

    @ViewBuilder
    private var dragPreview: some View {
        switch entry {
        case .app(let path):
            Image(nsImage: IconCache.shared.icon(for: path))
                .resizable().frame(width: layout.iconSize, height: layout.iconSize)
        case .folder(let folder):
            FolderIcon(store: store, folder: folder, size: layout.iconSize)
        }
    }

    private func open() {
        switch entry {
        case .app(let path):
            if let app = store.apps[path] { store.launch(app) }
        case .folder(let folder):
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { store.openFolderID = folder.id }
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
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if mergeTarget {
                    RoundedRectangle(cornerRadius: iconSize * 0.26)
                        .fill(.clear)
                        .frame(width: iconSize * 1.15, height: iconSize * 1.15)
                        .glassEffect(.regular, in: .rect(cornerRadius: iconSize * 0.26))
                }
                Image(nsImage: IconCache.shared.icon(for: app.id))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .scaleEffect(mergeTarget ? 0.82 : (hovering ? 1.05 : 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
            .frame(width: iconSize * 1.15, height: iconSize * 1.15)
            Text(app.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: iconSize * 1.5)
        }
        .padding(8)
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

    var body: some View {
        let mini = size * 0.22
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: size * 0.05), count: 3), spacing: size * 0.05) {
            ForEach(folder.apps.prefix(9), id: \.self) { path in
                Image(nsImage: IconCache.shared.icon(for: path))
                    .resizable()
                    .frame(width: mini, height: mini)
            }
        }
        .frame(width: size * 0.86, height: size * 0.86)
        .glassEffect(.regular, in: .rect(cornerRadius: size * 0.24))
        .frame(width: size, height: size)
    }
}

struct FolderCell: View {
    let store: LaunchpadStore
    let folder: Folder
    let iconSize: CGFloat
    var highlighted = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 7) {
            FolderIcon(store: store, folder: folder, size: iconSize)
                .scaleEffect(highlighted ? 1.15 : (hovering ? 1.05 : 1))
                .frame(width: iconSize * 1.15, height: iconSize * 1.15)
            Text(folder.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: iconSize * 1.5)
        }
        .padding(8)
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

    var body: some View {
        let columns = min(max(folder.apps.count, 3), layout.columns - 1, 6)
        let cell = CGSize(width: min(layout.cell.width, 150), height: min(layout.cell.height, 150))
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.spring(duration: 0.3)) { store.closeFolder() } }
                .onDrop(of: [.text], delegate: FolderExitDropDelegate(store: store, folderID: folder.id))

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

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell.width), spacing: 0), count: columns), spacing: 0) {
                        ForEach(folder.apps, id: \.self) { path in
                            if let app = store.apps[path] {
                                AppCell(app: app, iconSize: min(layout.iconSize, cell.width * 0.7))
                                    .frame(width: cell.width, height: cell.height)
                                    .contentShape(Rectangle())
                                    .opacity(store.draggingID == path ? 0.3 : 1)
                                    .onTapGesture { store.launch(app) }
                                    .onDrag {
                                        store.draggingID = path
                                        return NSItemProvider(object: path as NSString)
                                    } preview: {
                                        Image(nsImage: IconCache.shared.icon(for: path))
                                            .resizable().frame(width: layout.iconSize, height: layout.iconSize)
                                    }
                                    .onDrop(of: [.text], delegate: FolderReorderDelegate(store: store, folderID: folder.id, target: path))
                                    .contextMenu { AppMenu(store: store, app: app, folderID: folder.id) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: min(CGFloat((folder.apps.count + columns - 1) / columns), 3) * cell.height)
            }
            .padding(30)
            .frame(width: CGFloat(columns) * cell.width + 60)
            .glassEffect(.regular, in: .rect(cornerRadius: 40))
            .environment(\.colorScheme, .dark)
        }
        .onChange(of: nameFocused) { _, focused in store.editingFolderName = focused }
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
                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { store.goToPage(page) }
                    }
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 2)
    }
}

struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Settings")
    }
}

/// Invisible strips at the screen edges that flip pages while dragging over them.
struct EdgeFlipZones: View {
    let store: LaunchpadStore

    var body: some View {
        HStack {
            zone(-1)
            Spacer()
            zone(1)
        }
    }

    private func zone(_ direction: Int) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 70)
            .onDrop(of: [.text], delegate: EdgeFlipDelegate(store: store, direction: direction))
    }
}

/// The blurred desktop picture sized to the whole screen, pinned to the top-left corner.
struct WallpaperBackground: View {
    let store: LaunchpadStore

    var body: some View {
        ZStack {
            if let wallpaper = store.wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: store.screenSize.width, height: store.screenSize.height)
                    .clipped()
            }
            Color.black.opacity(store.wallpaper == nil ? 0.22 : 0.12)
        }
        .frame(width: store.screenSize.width, height: store.screenSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}
