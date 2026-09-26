import SwiftUI
import SwiftData

extension Color {
    /// Warm gold used by everything card-related, so the toolbar button, the
    /// wallet and the window map read as one feature next to RCR's blue.
    static let cardGold = Color(red: 0.93, green: 0.72, blue: 0.31)
}

/// The wallet: which window gets which card, and the cards themselves.
///
/// The map sits above the list on purpose. The single most common question
/// before pressing fill is "what is about to go where", and answering it with
/// a picture of the actual grid beats any amount of explanatory text.
struct CardsView: View {
    /// True when hosted by the tab bar rather than presented as a sheet, in
    /// which case there is no Done button because there is nothing to dismiss.
    var isEmbedded: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\SavedCard.sortOrder), SortDescriptor(\SavedCard.createdAt)])
    private var cards: [SavedCard]

    let viewModel: BrowserViewModel

    private let vault = CardVault.shared
    @State private var isAddingCard: Bool = false
    @State private var editingCard: SavedCard?
    @State private var pendingDelete: SavedCard?
    @State private var revealedCardID: String?
    @State private var revealedNumber: String = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                windowMap
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Window map")
            } footer: {
                Text(mapFooter)
            }

            Section("Mode") {
                Picker("Mode", selection: modeBinding) {
                    ForEach(CardFillMode.allCases) { mode in
                        Text(mode.shortLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(vault.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: autoFillBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-fill on checkout")
                            Text("Fills by itself whenever a page with card fields loads.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wand.and.sparkles")
                            .foregroundStyle(Color.cardGold)
                    }
                }
            }

            Section {
                if cards.isEmpty {
                    emptyWallet
                } else {
                    ForEach(cards) { card in
                        cardRow(card)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: deleteAt)
                }
            } header: {
                HStack {
                    Text("Cards")
                    Spacer()
                    if cards.count > 1 {
                        Text("Drag to reorder")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textCase(nil)
                    }
                }
            } footer: {
                Text("Card numbers and security codes are stored in the device keychain, never in the app's database and never sent anywhere.")
            }
        }
        .navigationTitle("Cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if cards.count > 1 { EditButton() }
                    Button {
                        isAddingCard = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add card")
                }
            }
        }
        .task {
            vault.attach(modelContext: modelContext)
        }
        .onChange(of: cards) { _, _ in vault.refresh() }
        .sheet(isPresented: $isAddingCard) {
            NavigationStack { CardFormView(card: nil) }
        }
        .sheet(item: $editingCard) { card in
            NavigationStack { CardFormView(card: card) }
        }
        .alert("Couldn't do that", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete this card?",
            isPresented: .init(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let card = pendingDelete { vault.deleteCard(card) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its number and security code are removed from the keychain too.")
        }
    }

    // MARK: - Window map

    private var mapFooter: String {
        if cards.isEmpty { return "Save a card and it'll show up here, assigned to your windows." }
        switch vault.mode {
        case .sameAsLeader:
            return "Every window fills the same card."
        case .rotate where cards.count < mapWindowCount:
            return "\(cards.count) card\(cards.count == 1 ? "" : "s") across \(mapWindowCount) windows — the list repeats."
        case .rotate:
            return "Each window fills its own card."
        }
    }

    private var mapWindowCount: Int {
        viewModel.isQuadMode ? viewModel.quadController.cardWindowOrder.count : 1
    }

    private var mapColumns: Int {
        guard viewModel.isQuadMode else { return 1 }
        return max(1, viewModel.quadController.gridSize.columns)
    }

    /// One cell of the window map.
    ///
    /// `position` is the window's slot in the assignment order, and is nil for
    /// a cell that is switched off — the 3×3 centre in dual-site. Those cells
    /// are still drawn, as holes, because a map that silently drops them
    /// reshapes the grid: eight windows laid into three columns put the gap at
    /// the bottom-right instead of the middle, so every tile after the centre
    /// pointed at the wrong window.
    private struct MapCell: Identifiable {
        let id: Int
        let label: String
        let position: Int?
        let record: CardRecord?
    }

    private var mapCells: [MapCell] {
        guard viewModel.isQuadMode else {
            return [MapCell(id: 0, label: "Window", position: 0, record: vault.record(forPosition: 0))]
        }
        let controller = viewModel.quadController
        // Assignment slots come from the same order the fill itself walks, so
        // the map cannot disagree with where a card actually lands.
        var positionByIndex: [Int: Int] = [:]
        for (position, session) in controller.cardWindowOrder.enumerated() {
            positionByIndex[session.index] = position
        }
        // Walk the grid, not the enabled windows, so a hole stays where it is.
        return controller.sessions.prefix(controller.activeCount).map { session in
            guard let position = positionByIndex[session.index] else {
                return MapCell(id: session.index, label: session.id, position: nil, record: nil)
            }
            return MapCell(
                id: session.index,
                label: session.id,
                position: position,
                record: vault.record(forPosition: position)
            )
        }
    }

    private var windowMap: some View {
        VStack(spacing: 10) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 6),
                    count: mapColumns
                ),
                spacing: 6
            ) {
                ForEach(mapCells) { cell in
                    mapTile(cell)
                }
            }

            if vault.mode == .rotate && cards.count > 1 {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        vault.advanceRotation()
                    }
                } label: {
                    Label("Next Set", systemImage: "arrow.forward.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.cardGold)
            }
        }
    }

    @ViewBuilder
    private func mapTile(_ cell: MapCell) -> some View {
        let label = cell.label
        if cell.position == nil {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.tertiary)
                Image(systemName: "square.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text("Unused")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.10))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) is switched off in dual-site mode and fills no card")
        } else if let record = cell.record {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cardGold)
                Text("••\(record.last4.suffix(4))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cardGold.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.cardGold.opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) fills the card ending \(record.last4)")
        } else {
            Button {
                isAddingCard = true
            } label: {
                VStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("No card")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) has no card. Add one")
        }
    }

    // MARK: - Wallet rows

    private var emptyWallet: some View {
        VStack(spacing: 10) {
            Image(systemName: "creditcard")
                .font(.system(size: 30))
                .foregroundStyle(Color.cardGold)
            Text("No cards yet")
                .font(.headline)
            Text("Add a card and the button next to RCR fills it into every window.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                isAddingCard = true
            } label: {
                Label("Add Card", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cardGold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func cardRow(_ card: SavedCard) -> some View {
        let record = card.record
        let isRevealed = revealedCardID == card.id
        let expired = record.isExpired()
        return Button {
            toggleReveal(card)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.cardGold.opacity(0.22))
                        .frame(width: 38, height: 26)
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cardGold)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(isRevealed
                         ? CardNumber.formatted(revealedNumber, brand: record.brand)
                         : CardNumber.masked(last4: record.last4, brand: record.brand))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        Text(record.brand.displayName)
                        Text("·")
                        Text(record.expiryDisplay)
                            .foregroundStyle(expired ? Color.orange : Color.secondary)
                        if !card.cardholderName.isEmpty {
                            Text("·")
                            Text(card.cardholderName).lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if let windows = windowsUsing(card), !windows.isEmpty {
                        Text(windows)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cardGold)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = card
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editingCard = card
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editingCard = card }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                if !vault.duplicate(card) {
                    errorMessage = "This card's details couldn't be read from the keychain, so it wasn't duplicated."
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = card }
        }
    }

    /// Which windows this card is assigned to right now — the list view's
    /// half of the map, so the connection between order and window is visible
    /// while you drag.
    private func windowsUsing(_ card: SavedCard) -> String? {
        guard let cardIndex = cards.firstIndex(where: { $0.id == card.id }) else { return nil }
        let labels = mapCells.compactMap { cell -> String? in
            guard let position = cell.position,
                  vault.cardIndex(forPosition: position) == cardIndex else { return nil }
            return cell.label
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: " · ")
    }

    // MARK: - Actions

    private var modeBinding: Binding<CardFillMode> {
        Binding(get: { vault.mode }, set: { vault.mode = $0 })
    }

    private var autoFillBinding: Binding<Bool> {
        Binding(get: { vault.isAutoFillArmed }, set: { vault.isAutoFillArmed = $0 })
    }

    private func toggleReveal(_ card: SavedCard) {
        if revealedCardID == card.id {
            revealedCardID = nil
            revealedNumber = ""
            return
        }
        guard let secrets = vault.secrets(for: card.id) else {
            errorMessage = "This card's number couldn't be read from the keychain."
            return
        }
        revealedCardID = card.id
        revealedNumber = secrets.number
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = cards
        reordered.move(fromOffsets: source, toOffset: destination)
        vault.applyOrder(reordered)
    }

    private func deleteAt(_ offsets: IndexSet) {
        for index in offsets where cards.indices.contains(index) {
            vault.deleteCard(cards[index])
        }
    }
}
