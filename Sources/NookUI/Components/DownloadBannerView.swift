import SwiftUI
import NookDesign
import NookRuntime

struct DownloadBannerView: View {
    let tierName: String
    let progress: Double
    let transfer: DownloadTransferProgress?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(NookColors.local)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading \(tierName)")
                        .font(NookTypography.rowTitle)
                        .foregroundColor(NookColors.ink)

                    Text(statusText)
                        .font(NookTypography.badge)
                        .foregroundColor(NookColors.ink55)
                }

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(NookColors.local)
            }

            ProgressView(value: progress)
                .tint(NookColors.local)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.card)
                .fill(NookColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NookRadius.card)
                .strokeBorder(NookColors.local.opacity(0.25), lineWidth: 1)
        )
        .nookCardShadow()
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading \(tierName), \(Int(progress * 100)) percent")
    }

    private var statusText: String {
        if let transfer, transfer.totalBytes > 0 {
            let downloaded = AppStorageUsage.format(transfer.completedBytes)
            let total = AppStorageUsage.format(transfer.totalBytes)
            if progress >= 0.85 {
                return "Loading into memory…"
            }
            return "\(downloaded) of \(total) · stays on this iPhone"
        }

        if progress >= 0.85 {
            return "Loading into memory…"
        }
        return "Stays on this iPhone"
    }
}
