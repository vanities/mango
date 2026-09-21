import SwiftUI

/// Chrome that floats over the page instead of boxing it in.
///
/// The page runs edge to edge under everything here, so the controls are two glass capsules
/// inset from the margins rather than opaque bars that steal screen. They fade themselves out
/// a few seconds after you stop touching them.
struct ReaderControls: View {
    @Bindable var engine: ReaderEngine
    @Binding var showingSettings: Bool
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
            if engine.groups.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(engine.groupIndex) },
                        set: { engine.goToGroup(Int($0.rounded())); engine.keepControlsAwake() }
                    ),
                    in: 0...Double(max(1, engine.groups.count - 1)),
                    step: 1
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
                Section("This comic") {
                    Picker("Direction", selection: $engine.direction) {
                        ForEach(ReadingDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Layout", selection: $engine.mode) {
                        ForEach(ReaderMode.allCases, id: \.self) { Text($0.label).tag($0) }
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
