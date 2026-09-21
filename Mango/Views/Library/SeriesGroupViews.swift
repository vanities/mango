import SwiftUI

/// A stack in the grid: the first few covers fanned behind one another, the group's name, and
/// how many series it holds.
struct GroupCardView: View {
    let group: SeriesGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // Back to front, so the first member is on top.
                ForEach(Array(group.members.prefix(3).enumerated().reversed()), id: \.offset) { offset, member in
                    CoverView(coverID: member.coverID, title: member.name)
                        .scaleEffect(1 - CGFloat(offset) * 0.06)
                        .offset(x: CGFloat(offset) * 7, y: CGFloat(-offset) * 5)
                        .shadow(color: .black.opacity(offset == 0 ? 0.18 : 0.08), radius: 3, y: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                Label("\(group.members.count)", systemImage: "square.stack")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .glassEffect(in: .capsule)
                    .padding(6)
            }
            Text(group.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            Text("\(group.members.count) series · \(group.volumeCount) books")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inside a stack: its series in reading order. Each opens like any shelf.
struct GroupDetailView: View {
    let groupID: String
    let fallback: SeriesGroup

    @Environment(LibraryModel.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var group: SeriesGroup { library.group(id: groupID) ?? fallback }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 104,
                                                   maximum: sizeClass == .regular ? 200 : 140), spacing: 16)],
                      spacing: 22) {
                ForEach(group.members) { shelf in
                    NavigationLink(value: shelf.id) {
                        SeriesCardView(series: shelf, title: SeriesGrouping.shortName(of: shelf.name, in: group.name))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove From \(group.name)", systemImage: "square.stack.3d.up.slash") {
                            library.setGroup("", for: shelf)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Group With…: put a shelf in an existing stack or start one.
struct GroupPickerView: View {
    let shelf: Series

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                let current = library.group(containing: shelf)?.name
                let names = library.groupNames.filter { $0 != current }
                if !names.isEmpty {
                    Section("Stacks") {
                        ForEach(names, id: \.self) { name in
                            Button(name) {
                                library.setGroup(name, for: shelf)
                                dismiss()
                            }
                        }
                    }
                }
                Section {
                    TextField("Name, like the franchise", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Button("Start New Stack", action: save)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("New stack")
                } footer: {
                    Text("A stack needs two series. Parts named “… Part 2” and series sharing a name before “ - ” stack on their own.")
                }
            }
            .navigationTitle("Group \(shelf.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        library.setGroup(name, for: shelf)
        dismiss()
    }
}
