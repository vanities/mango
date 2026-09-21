import SwiftUI

struct GoalEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $settings.yearlyGoal, in: 1...1000, step: settings.yearlyGoal >= 100 ? 10 : 5) {
                        LabeledContent("Volumes this year", value: "\(settings.yearlyGoal)")
                    }
                } footer: {
                    Text("Counts every volume, chapter or novel you finish, plus anything you log from outside the app.")
                }
            }
            .navigationTitle("Yearly Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
