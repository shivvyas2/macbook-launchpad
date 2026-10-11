import SwiftUI

/// The "Organize Apps" assistant: proposes category folders, lets you trim them, then applies.
struct OrganizeOverlay: View {
    let store: LaunchpadStore
    @State private var keepExisting = true
    @State private var plan: [Folder] = []
    @State private var excluded: Set<UUID> = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Organize Apps")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Group your apps into folders by what they do. You can undo this afterwards.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Keep my existing folders", isOn: $keepExisting)
                    .toggleStyle(.switch)
                    .onChange(of: keepExisting) { _, _ in rebuild() }

                if plan.isEmpty {
                    Text("Everything is already organized.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach($plan, id: \.id) { $folder in
                                PlanRow(store: store, folder: $folder, included: Binding(
                                    get: { !excluded.contains(folder.id) },
                                    set: { if $0 { excluded.remove(folder.id) } else { excluded.insert(folder.id) } }
                                ))
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 420)
                }

                HStack {
                    let count = plan.filter { !excluded.contains($0.id) }.count
                    Text(count == 1 ? "1 folder" : "\(count) folders")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Organize") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                        .disabled(count == 0)
                }
            }
            .padding(28)
            .frame(maxWidth: 600)
            .padding(.horizontal, 24)
            .launchpadGlass(.regular, in: .rect(cornerRadius: 32))
            .environment(\.colorScheme, .dark)
        }
        .onAppear(perform: rebuild)
    }

    private func rebuild() {
        let candidates = keepExisting ? store.looseApps : Array(store.apps.values)
        plan = Organizer.plan(for: candidates)
        excluded = []
    }

    private func apply() {
        let chosen = plan.filter { !excluded.contains($0.id) }
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            store.applyOrganization(chosen, keepExistingFolders: keepExisting)
            store.showingOrganizer = false
        }
    }

    private func close() {
        withAnimation(.spring(duration: 0.3)) { store.showingOrganizer = false }
    }
}

private struct PlanRow: View {
    let store: LaunchpadStore
    @Binding var folder: Folder
    @Binding var included: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $included)
                .toggleStyle(.checkbox)
                .labelsHidden()
            TextField("Folder name", text: $folder.name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 120)
            HStack(spacing: -6) {
                ForEach(folder.apps.prefix(10), id: \.self) { path in
                    Image(nsImage: IconCache.shared.icon(for: path))
                        .resizable()
                        .frame(width: 28, height: 28)
                        .help(store.apps[path]?.name ?? "")
                }
            }
            Spacer(minLength: 0)
            Text("\(folder.apps.count)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(included ? 0.08 : 0.02), in: .rect(cornerRadius: 12))
        .opacity(included ? 1 : 0.5)
    }
}

/// Lets you pick apps to put into a folder.
struct AddAppsPicker: View {
    let store: LaunchpadStore
    let folderID: UUID
    let done: () -> Void
    @State private var filter = ""

    var body: some View {
        let inFolder = Set(store.openFolder?.apps ?? [])
        let candidates = store.apps.values
            .filter { !inFolder.contains($0.id) }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        VStack(spacing: 12) {
            HStack {
                TextField("Filter apps", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("Done", action: done)
                    .buttonStyle(.glassProminent)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 4), count: 6), spacing: 4) {
                    ForEach(candidates) { app in
                        Button {
                            withAnimation(.spring(duration: 0.3)) { store.addToFolder(folderID, app: app.id) }
                        } label: {
                            VStack(spacing: 4) {
                                Image(nsImage: IconCache.shared.icon(for: app.id))
                                    .resizable()
                                    .frame(width: 44, height: 44)
                                Text(app.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(width: 84, height: 74)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add \(app.name)")
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: 240)
        }
    }
}

/// Shown briefly after organizing, with an Undo button.
struct UndoToast: View {
    let store: LaunchpadStore

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Apps organized into folders")
            Button("Undo") {
                withAnimation(.spring(duration: 0.4)) { store.undoOrganization() }
            }
            .buttonStyle(.glass)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .launchpadGlass(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .task {
            try? await Task.sleep(for: .seconds(10))
            withAnimation { store.clearUndo() }
        }
    }
}
