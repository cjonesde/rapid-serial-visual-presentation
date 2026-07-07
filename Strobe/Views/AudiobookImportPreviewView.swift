import SwiftUI

struct AudiobookImportPreviewView: View {
    let preview: AudiobookImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var formattedDuration: String {
        let total = Int(preview.audioDuration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(StrobeTheme.accent.opacity(0.1))
                    .frame(width: 72, height: 72)
                Image(systemName: "headphones")
                    .font(.system(size: 32))
                    .foregroundStyle(StrobeTheme.accent)
            }
            .padding(.top, 32)

            VStack(spacing: 8) {
                Text(preview.title)
                    .font(StrobeTheme.titleFont(size: 24))
                    .foregroundStyle(StrobeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text("\(formattedDuration) · \(preview.wordCount) words · \(preview.segmentCount) segments")
                    .font(StrobeTheme.bodyFont(size: 14))
                    .foregroundStyle(StrobeTheme.textSecondary)
            }

            Text(preview.previewWords.joined(separator: " ") + (preview.wordCount > preview.previewWords.count ? " ..." : ""))
                .font(StrobeTheme.bodyFont(size: 16))
                .foregroundStyle(StrobeTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(StrobeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)

            Text("Check that these opening words match the audiobook before importing.")
                .font(StrobeTheme.bodyFont(size: 13))
                .foregroundStyle(StrobeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(StrobeTheme.textPrimary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text("Import")
                        .font(StrobeTheme.bodyFont(size: 16, bold: true))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(StrobeTheme.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrobeTheme.Gradients.mainBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
