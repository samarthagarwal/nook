import SwiftUI
import NookDesign
import NookCore

/// Collapsed-by-default card for large external MCP tool results.
public struct ExternalToolResultCard: View {
    public let execution: ExternalToolExecution

    @State private var isExpanded = false

    public init(execution: ExternalToolExecution) {
        self.execution = execution
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    PrivacyRing(accessibilityText: "External MCP tool executed")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(execution.toolName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(NookColors.external)
                        Text(summaryLabel)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(NookColors.ink55)
                            .lineLimit(isExpanded ? 1 : 2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NookColors.ink40)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse tool result" : "Expand tool result")
            .accessibilityValue(execution.toolName)

            if isExpanded {
                ScrollView {
                    Text(expandedBody)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundColor(NookColors.ink70)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 280)

                if !execution.footer.isEmpty {
                    Text(execution.footer)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundColor(NookColors.external.opacity(0.75))
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.card)
                .fill(NookColors.externalSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NookRadius.card)
                .strokeBorder(NookColors.externalHairline, lineWidth: 1)
        )
    }

    private var summaryLabel: String {
        let nonEmpty = execution.lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if nonEmpty.isEmpty {
            return isExpanded ? "Tool result" : "No output · tap to expand"
        }
        let chars = nonEmpty.joined(separator: "\n").count
        let preview = nonEmpty[0]
        let clipped = preview.count > 90 ? String(preview.prefix(87)) + "…" : preview
        if isExpanded {
            return "\(nonEmpty.count) lines · \(chars) chars"
        }
        return "\(nonEmpty.count) lines · \(clipped)"
    }

    private var expandedBody: String {
        let body = execution.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "(empty result)" : body
    }
}
