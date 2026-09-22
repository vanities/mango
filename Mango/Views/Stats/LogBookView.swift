import SwiftUI
import ShelfKit

/// Log a book read outside Mango so Stats counts it — years of reading from before the app,
/// or a volume borrowed and given back.
struct LogBookView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var series = ""
    @State private var isNovel = false
    @State private var finishedAt = Date()
    @State private var rating: Int?
    @State private var pages = ""

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Series (optional)", text: $series)
                    Picker("Kind", selection: $isNovel) {
                        Text("Manga / comic").tag(false)
                        Text("Light novel").tag(true)
                    }
                }
                Section {
                    DatePicker("Finished", selection: $finishedAt, in: ...Date(), displayedComponents: .date)
                    LabeledContent("Pages") {
                        TextField("optional", text: $pages)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("Pages are optional; they only feed the pages-read total.")
                }
                Section("Rating") {
                    StarRating(rating: rating) { rating = $0 }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Log a Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.logBook(ReadingLogEntry(
                            title: title.trimmingCharacters(in: .whitespaces),
                            series: series.nilIfEmpty,
                            isNovel: isNovel,
                            finishedAt: finishedAt,
                            rating: rating,
                            pages: Int(pages)
                        ))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
