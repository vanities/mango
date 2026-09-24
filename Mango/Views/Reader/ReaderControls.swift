import SwiftUI

/// Chrome that floats over the page instead of boxing it in.
///
/// The page runs edge to edge under everything here, so the controls are two glass capsules
/// inset from the margins rather than opaque bars that steal screen. They fade themselves out
/// a few seconds after you stop touching them.
struct ReaderControls: View {
    @Bindable var engine: ReaderEngine
    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers
    @Binding var showingSettings: Bool
    @Binding var showingPages: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        // The reader is a black room. Render the chrome for that room rather than for the
        // system appearance, or the glass comes out milky grey against the page.
        .environment(\.colorScheme, .dark)
        .opacity(engine.showsControls ? 1 : 0)
        .allowsHitTesting(engine.showsControls)
        // Opacity alone leaves the buttons in the accessibility tree, so VoiceOver would offer
        // controls that can't be hit. Take them out of the tree while they're faded away.
        .accessibilityHidden(!engine.showsControls)
        .animation(.smooth(duration: 0.25), value: engine.showsControls)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 10) {
            button("chevron.left", label: "Close", action: onClose)

            VStack(alignment: .leading, spacing: 0) {
                Text(engine.comic.numberLabel ?? engine.comic.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(engine.comic.series ?? engine.comic.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            downloadButton
            button("square.grid.2x2", label: "All pages") {
                showingPages = true
                engine.keepControlsAwake()
            }
            button(engine.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                   label: engine.isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page") {
                engine.toggleBookmark()
            }
            button(engine.direction.systemImage, label: "Reading direction: \(engine.direction.label)") {
                engine.direction = engine.direction == .rightToLeft ? .leftToRight : .rightToLeft
                engine.keepControlsAwake()
            }
            button(engine.mode.systemImage, label: "Reader settings") {
                showingSettings = true
                engine.keepControlsAwake()
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .glassEffect(in: .capsule)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// Reading off the NAS: one tap keeps a copy on this device, downloading while you read. A
    /// ring while it comes down; a check once it's here. Nothing for a comic with no NAS copy.
    @ViewBuilder
    private var downloadButton: some View {
        if let nas = library.nasCopy(of: engine.comic) {
            if let job = transfers.job(for: nas.id), job.isActive {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                    Circle().trim(from: 0, to: max(0.02, job.fraction))
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .frame(width: 40, height: 40)
                .accessibilityElement()
                .accessibilityLabel("Downloading, \(Int(job.fraction * 100)) percent")
            } else if library.downloadedCopy(of: engine.comic) != nil {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("Downloaded to this device")
            } else {
                button("arrow.down.circle", label: "Download to this device") {
                    transfers.download(nas)
                    engine.keepControlsAwake()
                }
            }
        }
    }

    private func button(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                // 44pt: this gets used one-handed, often in bed.
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let page = engine.jumpOrigin {
                button("arrow.uturn.backward", label: "Return to page \(page + 1)") { engine.undoJump() }
            }
            if engine.groups.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(engine.groupIndex) },
                        set: { engine.scrub(to: Int($0.rounded())); engine.keepControlsAwake() }
                    ),
                    in: 0...Double(max(1, engine.groups.count - 1)),
                    step: 1,
                    onEditingChanged: { if $0 { engine.beginJump() } }
                )
                // The slider runs the way the pages do, so dragging "forward" is the same
                // gesture as turning forward.
                .environment(\.layoutDirection, engine.direction == .rightToLeft ? .rightToLeft : .leftToRight)
                .tint(.white)
            }
            // Compact and monospaced so the capsule doesn't twitch as the number grows.
            Text("\(engine.currentPage + 1) / \(engine.pageCount)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

/// Per-comic reader options, reachable without leaving the page you're on.
struct ReaderSettingsSheet: View {
    @Bindable var engine: ReaderEngine
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Page tint", selection: $settings.pageFilter) {
                        ForEach(PageFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "moon.stars.fill")
                            .font(.title2)
                        Text("Paper and ink preview")
                            .font(.body.weight(.medium))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(.white)
                    .pageFilter(settings.pageFilter)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("Page tint preview: \(settings.pageFilter.label)")
                } header: {
                    Text("Night reading")
                } footer: {
                    Text("Tan paper and Red light soften white pages while keeping dark ink. Applies to all comics, including page thumbnails. Your files stay unchanged.")
                }
                if !engine.bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(engine.bookmarks) { mark in
                            Button {
                                engine.goToPage(mark.page)
                                dismiss()
                            } label: {
                                HStack {
                                    Label(mark.label(isNovel: false), systemImage: "bookmark.fill")
                                    Spacer()
                                    Text(mark.createdAt, format: .dateTime.month().day())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { engine.removeBookmark(mark) } }
                        }
                    }
                }
                Section {
                    Picker("Direction", selection: $engine.direction) {
                        ForEach(ReadingDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Layout", selection: Binding(get: { engine.mode }, set: { engine.chooseMode($0) })) {
                        ForEach(ReaderMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text(engine.comic.series == nil ? "This comic" : "This series")
                } footer: {
                    // Both are saved for the whole series, so a webtoon needs setting only once.
                    if let series = engine.comic.series {
                        Text("Applies to every volume and chapter of \(series).")
                    }
                }
                Section("Everywhere") {
                    Picker("Page fit", selection: $settings.pageFit) {
                        ForEach(PageFit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Two-page spreads", selection: $settings.spreadMode) {
                        ForEach(SpreadMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Dragging sideways", selection: $settings.horizontalPan) {
                        ForEach(PanDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Dragging up and down", selection: $settings.verticalPan) {
                        ForEach(PanDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Tap edges to turn", isOn: $settings.tapToTurn)
                    Toggle("Keep screen awake", isOn: $settings.keepScreenAwake)
                    Toggle("Black background", isOn: $settings.blackBackground)
                    Toggle("Crop margins", isOn: $settings.cropMargins)
                }
                Section {
                    Picker("Pages to load ahead", selection: $settings.prefetchCount) {
                        ForEach(AppSettings.prefetchChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                } footer: {
                    Text("More pages ahead means instant turns and more memory. Three is a good balance over a network.")
                }
            }
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
