import SwiftUI

/// Display mode for the phonebook grid.
enum PhonebookViewMode: String, CaseIterable {
    case list = "List"
    case smallTiles = "Small"
    case mediumTiles = "Medium"
    case largeTiles = "Large"

    var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .smallTiles: return "square.grid.3x3"
        case .mediumTiles: return "square.grid.2x2"
        case .largeTiles: return "rectangle.grid.1x2"
        }
    }

    /// Snapshot size: exact 4:3, the whole raw 16:10 snapshot stretched into it the way the
    /// terminal's display does (Windows: small 129×97, medium 172×129, large 216×162).
    var imageSize: CGSize {
        switch self {
        case .list: return CGSize(width: 52, height: 39)
        case .smallTiles: return CGSize(width: 129, height: 97)
        case .mediumTiles: return CGSize(width: 172, height: 129)
        case .largeTiles: return CGSize(width: 216, height: 162)
        }
    }

    /// Tile = snapshot + 4 padding + 2 border each side (large: 216 wide snapshot, 228 tile).
    var tileWidth: CGFloat { imageSize.width + 12 }
}

/// Desktop-optimized phonebook view with configurable tile sizes.
/// Mirrors the Windows PhonebookView layout.
struct PhonebookView: View {
    @StateObject private var store = BBSEntryStore.shared
    @EnvironmentObject var appState: AppState

    @AppStorage("phonebook_view_mode") private var viewModeRaw: String = PhonebookViewMode.mediumTiles.rawValue
    @State private var selectedEntry: BBSEntry?
    @State private var showingAddSheet = false
    @State private var editingEntry: BBSEntry?
    @State private var showingDeleteConfirm = false
    @State private var entryToDelete: BBSEntry?
    @State private var snapshotPreviewEntry: BBSEntry?
    @State private var draggingEntry: BBSEntry?

    private var viewMode: PhonebookViewMode {
        PhonebookViewMode(rawValue: viewModeRaw) ?? .mediumTiles
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header (matches Windows: title + subtitle)
            VStack(spacing: 2) {
                Text("PHONEBOOK")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(.amberAccent)
                Text("Saved BBS Connections")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Toolbar row
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.backgroundMedium)

            Rectangle()
                .fill(Color.panelBorder)
                .frame(height: 1)

            // Content
            if store.entries.isEmpty {
                emptyState
            } else if viewMode == .list {
                listView
            } else {
                gridView
            }

            // Call log line for the selected board (matches Windows: above the bottom bar)
            Text(selectedEntry.map { "\($0.name): \(CallStatsService.shared.describe($0.id.uuidString))" } ?? " ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)

            // Bottom bar (matches Windows: BACK left, view mode label right)
            HStack {
                RetroButton("BACK", style: .green) {
                    appState.currentView = .home
                }

                Spacer()

                Text(viewMode.rawValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.accentGreen)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.backgroundMedium)
        }
        .background(Color.background)
        .sheet(isPresented: $showingAddSheet) {
            ConnectionEditorView(entry: nil) { newEntry in
                store.addEntry(newEntry)
            }
        }
        .sheet(item: $editingEntry) { entry in
            ConnectionEditorView(entry: entry) { updatedEntry in
                store.updateEntry(updatedEntry)
                // Keep selectedEntry in sync so subsequent EDITs show updated values
                if selectedEntry?.id == updatedEntry.id {
                    selectedEntry = updatedEntry
                }
            }
        }
        .overlay {
            // Snapshot preview overlay
            if let previewEntry = snapshotPreviewEntry,
               let data = previewEntry.snapshotData,
               let img = NSImage(data: data) {
                Color.black.opacity(0.75)
                    .ignoresSafeArea()
                    .onTapGesture {
                        snapshotPreviewEntry = nil
                    }
                    .overlay {
                        VStack(spacing: 12) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 640, maxHeight: 480)
                                .cornerRadius(8)
                                .shadow(color: .black.opacity(0.5), radius: 20)

                            Text(previewEntry.name)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)

                            Text("Click anywhere to dismiss")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: snapshotPreviewEntry != nil)
        .alert("Delete Connection", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    store.deleteEntry(entry)
                    if selectedEntry?.id == entry.id {
                        selectedEntry = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(entryToDelete?.name ?? "")\"?")
        }
    }

    // MARK: - Toolbar (matches Windows: ADD, EDIT, DELETE | CONNECT ... VIEW)

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Left: action buttons
            RetroButton("ADD", style: .green) {
                showingAddSheet = true
            }

            RetroButton("EDIT", style: .green) {
                if let entry = selectedEntry {
                    editingEntry = entry
                }
            }
            .disabled(selectedEntry == nil)
            .opacity(selectedEntry == nil ? 0.5 : 1.0)

            RetroButton("DELETE", style: .danger) {
                if let entry = selectedEntry {
                    entryToDelete = entry
                    showingDeleteConfirm = true
                }
            }
            .disabled(selectedEntry == nil)
            .opacity(selectedEntry == nil ? 0.5 : 1.0)

            // Separator
            Rectangle()
                .fill(Color.panelBorder)
                .frame(width: 1, height: 28)
                .padding(.horizontal, 10)

            RetroButton("CONNECT", style: .amber) {
                if let entry = selectedEntry {
                    connectTo(entry)
                }
            }
            .disabled(selectedEntry == nil)
            .opacity(selectedEntry == nil ? 0.5 : 1.0)

            RetroButton(store.isSortedAlphabetically ? "UNSORT" : "SORT", style: .green) {
                store.sortEntriesAlphabetically()
            }

            Spacer()

            // Right: VIEW button cycles modes
            RetroButton("VIEW", style: .green) {
                cycleViewMode()
            }
        }
    }

    private func cycleViewMode() {
        let modes = PhonebookViewMode.allCases
        if let idx = modes.firstIndex(of: viewMode) {
            let next = modes[(idx + 1) % modes.count]
            viewModeRaw = next.rawValue
        }
    }

    // MARK: - Grid View

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(store.entries) { entry in
                    phonebookTile(entry)
                        .opacity(draggingEntry?.id == entry.id ? 0.4 : 1.0)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editingEntry = entry
                        }
                        .onTapGesture(count: 1) {
                            selectedEntry = entry
                        }
                        .contextMenu {
                            entryContextMenu(entry)
                        }
                        .draggable(entry.id.uuidString) {
                            phonebookTile(entry)
                                .frame(width: viewMode.tileWidth)
                                .opacity(0.8)
                                .onAppear {
                                    draggingEntry = entry
                                }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let draggedIDString = items.first,
                                  let draggedID = UUID(uuidString: draggedIDString),
                                  let fromIndex = store.entries.firstIndex(where: { $0.id == draggedID }),
                                  let toIndex = store.entries.firstIndex(where: { $0.id == entry.id }),
                                  fromIndex != toIndex else {
                                return false
                            }
                            let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
                            store.moveEntries(from: IndexSet(integer: fromIndex), to: destination)
                            draggingEntry = nil
                            return true
                        } isTargeted: { _ in }
                }
            }
            .padding(16)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            draggingEntry = nil
            return false
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: viewMode.tileWidth, maximum: viewMode.tileWidth * 1.5), spacing: 12)]
    }

    // MARK: - List View

    private var listView: some View {
        List(selection: Binding(
            get: { selectedEntry?.id },
            set: { id in selectedEntry = store.entries.first { $0.id == id } }
        )) {
            ForEach(store.entries) { entry in
                PhonebookRowView(entry: entry, isSelected: selectedEntry?.id == entry.id)
                .tag(entry.id)
                .contextMenu {
                    entryContextMenu(entry)
                }
            }
            .onMove { source, destination in
                store.moveEntries(from: source, to: destination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Tile

    private func phonebookTile(_ entry: BBSEntry) -> some View {
        PhonebookTileView(entry: entry, viewMode: viewMode, isSelected: selectedEntry?.id == entry.id)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func entryContextMenu(_ entry: BBSEntry) -> some View {
        Button("Connect") { connectTo(entry) }
        Divider()
        Button("Edit...") { editingEntry = entry }
        if entry.snapshotData != nil {
            Button("View Snapshot") { snapshotPreviewEntry = entry }
        }
        Button("Delete", role: .destructive) {
            entryToDelete = entry
            showingDeleteConfirm = true
        }
        Divider()
        Button("Set as Quick Connect 1") {
            UserDefaults.standard.set(entry.id.uuidString, forKey: "quick_connect_1_id")
        }
        Button("Set as Quick Connect 2") {
            UserDefaults.standard.set(entry.id.uuidString, forKey: "quick_connect_2_id")
        }
        // Slots 3–4 only show in the side-by-side home layout, but stay saved while hidden.
        Button("Set as Quick Connect 3") {
            UserDefaults.standard.set(entry.id.uuidString, forKey: "quick_connect_3_id")
        }
        Button("Set as Quick Connect 4") {
            UserDefaults.standard.set(entry.id.uuidString, forKey: "quick_connect_4_id")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.textSecondary)
            Text("No Connections")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.onBackground)
            Text("Add a BBS connection to get started")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.textSecondary)
            Button("Add Connection") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Actions

    private func connectTo(_ entry: BBSEntry) {
        store.updateLastConnected(for: entry)
        // A window of its own, or here (Options > Separate Window per BBS)
        SessionLauncher.connect(entry)
    }
}

// MARK: - Tile and row views

/// One phonebook grid tile: 4:3 snapshot (stretched, nearest-neighbor) over the name, address
/// and (not small) connection description. Same hover look as the home tiles: amber border,
/// lifted background, amber glow. A selected tile keeps a plain amber border.
private struct PhonebookTileView: View {
    let entry: BBSEntry
    let viewMode: PhonebookViewMode
    let isSelected: Bool

    var body: some View {
        let imageSize = viewMode.imageSize

        VStack(spacing: 4) {
            // Snapshot image (no tap gesture — whole tile handles selection)
            if let data = entry.snapshotData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: imageSize.width, height: imageSize.height)
            } else {
                Rectangle()
                    .fill(Color.background)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .overlay(
                        Image(systemName: "tv")
                            .font(.system(size: 24))
                            .foregroundColor(.textSecondary.opacity(0.5))
                    )
            }

            VStack(spacing: 2) {
                Text(entry.name)
                    .font(.system(size: viewMode == .smallTiles ? 10 : 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentGreen)
                    .lineLimit(1)

                Text(entry.addressDisplay)
                    .font(.system(size: viewMode == .smallTiles ? 9 : 10, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)

                if viewMode != .smallTiles {
                    Text(entry.connectionDescription)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.textSecondary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(width: imageSize.width)
            .padding(.bottom, 2)
        }
        .padding(6)
        .tileHover(selected: isSelected)
    }
}

/// One phonebook list row, with the same hover glow as the tiles.
private struct PhonebookRowView: View {
    let entry: BBSEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Small 4:3 thumbnail
            if let data = entry.snapshotData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: PhonebookViewMode.list.imageSize.width,
                           height: PhonebookViewMode.list.imageSize.height)
                    .cornerRadius(3)
            } else {
                Rectangle()
                    .fill(Color.crtBackground)
                    .frame(width: PhonebookViewMode.list.imageSize.width,
                           height: PhonebookViewMode.list.imageSize.height)
                    .cornerRadius(3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightGreen)

                Text(entry.addressDisplay)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            Text(entry.connectionProtocol.displayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.appPrimary)

            Text(entry.screenMode.displayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSecondary)

            if let lastConnected = entry.lastConnected {
                Text(lastConnected, style: .relative)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .tileHover(selected: isSelected, cornerRadius: 3)
    }
}

// MARK: - Connection Editor

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let entry: BBSEntry?
    let onSave: (BBSEntry) -> Void

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "23"
    @State private var connectionProtocol: ConnectionProtocol = .telnet
    /// What the protocol picker held before the current change — used to decide
    /// whether the port field is still on a default and may be swapped.
    @State private var previousProtocol: ConnectionProtocol = .telnet
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var saveCredentials: Bool = false
    @State private var screenMode: ScreenMode = .mode80x25
    @State private var font: TerminalFont = .cp437
    @State private var showStatusBar: Bool = true
    @State private var didLoad: Bool = false

    init(entry: BBSEntry?, onSave: @escaping (BBSEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text(entry == nil ? "Add Connection" : "Edit Connection")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.appPrimary)
                .padding()

            Divider()

            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                    Picker("Protocol", selection: $connectionProtocol) {
                        ForEach(ConnectionProtocol.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                }

                Section("Authentication") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    Toggle("Save Credentials", isOn: $saveCredentials)
                }

                Section("Terminal") {
                    Picker("Screen Mode", selection: $screenMode) {
                        ForEach(ScreenMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Picker("Font", selection: $font) {
                        ForEach(TerminalFont.allCases) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    Toggle("Show Status Bar", isOn: $showStatusBar)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveEntry()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || host.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .background(Color.surface)
        .onAppear {
            if let entry = entry {
                name = entry.name
                host = entry.host
                port = String(entry.port)
                connectionProtocol = entry.connectionProtocol
                previousProtocol = entry.connectionProtocol
                username = entry.username
                let storedPassword = entry.password ?? ""
                password = storedPassword
                // Default Save Credentials to true if a password is stored, matching
                // Windows behavior (re-opens an entry with credentials still saved).
                saveCredentials = !storedPassword.isEmpty
                screenMode = entry.screenMode
                font = entry.font
                showStatusBar = entry.showStatusBar
            }
            // Mark initial load complete on next run loop
            DispatchQueue.main.async {
                didLoad = true
            }
        }
        .onChange(of: connectionProtocol) { newProtocol in
            // Changing protocol swaps in that protocol's default port, but only if
            // the port field still holds the PREVIOUS protocol's default (or is
            // empty) — a custom port the user typed is left alone.
            //
            // Telnet <-> Raw is deliberately a no-op here: both default to 23, because
            // Raw exists precisely for boards that answer on the telnet port without
            // speaking telnet. Switching between the two keeps whatever port is there.
            guard didLoad else { return }
            if port.trimmingCharacters(in: .whitespaces).isEmpty
                || Int(port.trimmingCharacters(in: .whitespaces)) == previousProtocol.defaultPort {
                port = String(newProtocol.defaultPort)
            }
            previousProtocol = newProtocol
        }
    }

    private func saveEntry() {
        var updated = entry ?? BBSEntry()
        updated.name = name
        updated.host = host
        updated.port = Int(port) ?? 23
        updated.connectionProtocol = connectionProtocol
        updated.username = username
        updated.screenMode = screenMode
        updated.font = font
        updated.showStatusBar = showStatusBar

        // Save Credentials behavior (matches Windows):
        //   - checked + non-empty password → write to Keychain
        //   - unchecked                    → delete any stored password
        if saveCredentials && !password.isEmpty {
            updated.setPassword(password)
        } else if !saveCredentials {
            updated.setPassword(nil)
        }

        onSave(updated)
        dismiss()
    }
}
