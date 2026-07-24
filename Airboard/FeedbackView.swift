//
//  FeedbackView.swift
//  Airboard
//

import SwiftUI

struct FeedbackView: View {
    let transcribedText: String
    let context: AppContext?
    let onSubmit: (String?) -> Void
    let onClose: () -> Void

    @State private var comment: String = ""
    @State private var isSubmitting: Bool = false
    @State private var showingConfirmation: Bool = false
    @FocusState private var isCommentFocused: Bool

    var body: some View {
        ZStack {
            if showingConfirmation {
                confirmationView
            } else {
                formView
            }
        }
        .frame(width: 480, height: 400)
        .background(DS.Surface.panel)
    }

    private var formView: some View {
        VStack(spacing: 0) {
            // Header - Fixed height
            VStack(spacing: 8) {
                Text("Report Transcription Issue")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Label.primary)

                if let context = context {
                    Text("\(context.appName) • \(context.appType.description)")
                        .font(.caption)
                        .foregroundColor(DS.Label.secondary)
                }
            }
            .frame(height: 50)
            .padding(.top, 16)

            Divider()
                .padding(.vertical, 12)

            // Scrollable content area - Takes remaining space
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Transcribed text section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Airboard transcribed:")
                            .font(.subheadline)
                            .foregroundColor(DS.Label.secondary)

                        Text(transcribedText)
                            .font(.body)
                            .foregroundColor(DS.Label.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(DS.Fill.quaternary)
                            .cornerRadius(DS.Radius.r8)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Comment section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Additional comments (optional):")
                            .font(.subheadline)
                            .foregroundColor(DS.Label.secondary)

                        ZStack(alignment: .topLeading) {
                            // Background
                            RoundedRectangle(cornerRadius: DS.Radius.r8)
                                .fill(DS.Surface.control)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.r8)
                                        .stroke(DS.Border.hairline, lineWidth: 1)
                                )

                            // TextEditor
                            TextEditor(text: $comment)
                                .font(.body)
                                .foregroundColor(DS.Label.primary)
                                .padding(8)
                                .frame(height: 100)
                                .background(Color.clear)
                                .focused($isCommentFocused)
                                .scrollContentBackground(.hidden)

                            // Placeholder
                            if comment.isEmpty {
                                Text("Optionally describe what went wrong or what you expected")
                                    .font(.body)
                                    .foregroundColor(DS.Label.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(height: 100)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .padding(.top, 12)

            // Buttons - Fixed height
            HStack(spacing: 12) {
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Spacer()

                Button(isSubmitting ? "Sending..." : "Send Report") {
                    submitFeedback()
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
            .frame(height: 44)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var confirmationView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(DS.Accent.success)

                VStack(spacing: 8) {
                    Text("Issue Reported!")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(DS.Label.primary)

                    Text("Thank you for helping improve Airboard.")
                        .font(.body)
                        .foregroundColor(DS.Label.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            Text("This window will close automatically...")
                .font(.caption)
                .foregroundColor(DS.Label.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Auto-close after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                onClose()
            }
        }
    }

    private func submitFeedback() {
        isSubmitting = true

        let finalComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(finalComment.isEmpty ? nil : finalComment)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showingConfirmation = true
            }
        }
    }
}

/// DS primary CTA: accent fill, on-accent label, r8 radius. Dims when disabled.
/// Local replica of CleanupSettingsView's private DSPrimaryButtonStyle (Task 3
/// precedent) — kept file-private rather than widening access.
private struct DSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Label.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.r8)
                    .fill(DS.Accent.primary)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

struct FeedbackView_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackView(
            transcribedText: "This is a really long transcription that goes on and on and on to test the scrolling behavior of the view. It should wrap properly and not cause any overflow issues.",
            context: AppContext(appName: "Claude", appType: .general),
            onSubmit: { _ in },
            onClose: { }
        )
    }
}
