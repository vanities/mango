import SwiftUI
import VisionKit
import os

/// An explicit mode: normal page turns never compete with text selection gestures.
struct LiveTextPageView: View {
    let engine: ReaderEngine
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var analysis: ImageAnalysis?
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Group {
                if let image, let analysis {
                    LiveTextImage(image: image, analysis: analysis)
                } else if let message {
                    ContentUnavailableView("Text selection unavailable", systemImage: "text.viewfinder", description: Text(message))
                } else { ProgressView("Finding text on page \(index + 1)…") }
            }
            .navigationTitle("Select page text")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                guard ImageAnalyzer.isSupported else { message = "Live Text isn't supported on this device."; return }
                guard let cgImage = await engine.image(at: index) else { message = "This page couldn't be loaded."; return }
                let image = UIImage(cgImage: cgImage)
                do {
                    let result = try await ImageAnalyzer().analyze(image, configuration: .init([.text]))
                    guard !Task.isCancelled else { return }
                    if result.hasResults(for: .text) { self.image = image; analysis = result } else { message = "No selectable text was found on this page." }
                } catch {
                    Logger.reader.error("[live-text] page=\(index) failed: \(error.localizedDescription, privacy: .public)")
                    message = error.localizedDescription
                }
            }
        }
    }
}

struct LiveTextImage: UIViewRepresentable {
    let image: UIImage
    let analysis: ImageAnalysis
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .textSelection
        view.addInteraction(interaction)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        view.image = image
        (view.interactions.first { $0 is ImageAnalysisInteraction } as? ImageAnalysisInteraction)?.analysis = analysis
    }
}
