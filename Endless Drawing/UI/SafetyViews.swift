import SwiftUI

/// Shown once (per terms version) on the first attempt to draw; viewing never asks (App Review 1.2).
struct TermsSheet: View {
    @Bindable var model: CanvasModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you draw").font(.title2.bold())
            Text("Everything here is public and stays visible to everyone.")
            Text("No sexual, violent, hateful or illegal drawings — they are removed and their authors blocked.")
            Link("Terms of Use", destination: CanvasModel.termsURL)
            Spacer(minLength: 0)
            Button { model.acceptTerms() } label: { Text("I agree").frame(maxWidth: .infinity, minHeight: 32) }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }
}

/// Report mode banner: taps select strokes, fingers still move the canvas.
struct ReportBar: View {
    @Bindable var model: CanvasModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(model.reportSelection.isEmpty ? String(localized: "Tap drawings to report")
                 : String(localized: "Selected: \(model.reportSelection.count)"))
                .monospacedDigit()
            Button("Report") { model.reportSheet = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.reportSelection.isEmpty)
            Button { model.reporting = false } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Cancel report"))
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

/// Reason and blocking for the selected strokes.
struct ReportSheet: View {
    @Bindable var model: CanvasModel
    @State private var reason: ReportReason?
    @State private var blockAuthor = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ReportReason.allCases, id: \.self) { option in
                        Button { reason = option } label: {
                            HStack {
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if reason == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(reason == option ? .isSelected : [])
                    }
                } header: { Text("What’s wrong?") }
                Section {
                    Toggle("Hide everything from this author", isOn: $blockAuthor)
                } footer: {
                    Text("Reported drawings disappear for you right away. We review reports within 24 hours.")
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.reportSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { if let reason { model.submitReport(reason: reason, blockAuthor: blockAuthor) } }
                        .disabled(reason == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension ReportReason {
    var title: String {
        switch self {
        case .sexual: String(localized: "Sexual content")
        case .violence: String(localized: "Violence or threats")
        case .hate: String(localized: "Hate or harassment")
        case .illegal: String(localized: "Illegal content")
        case .spam: String(localized: "Spam or flooding")
        case .other: String(localized: "Something else")
        }
    }
}

/// Short confirmation at the bottom; disappears by itself.
struct NoticeToast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
