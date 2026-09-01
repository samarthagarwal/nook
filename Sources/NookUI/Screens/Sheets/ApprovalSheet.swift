import SwiftUI
import NookDesign
import NookCore

public struct ApprovalSheet: View {
    public let payload: OutgoingApprovalPayload
    public let onAction: (ApprovalAction) -> Void
    
    public init(payload: OutgoingApprovalPayload, onAction: @escaping (ApprovalAction) -> Void) {
        self.payload = payload
        self.onAction = onAction
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Eyebrow
            HStack(spacing: 6) {
                PrivacyRing(accessibilityText: "External transfer")
                Text("LEAVING YOUR DEVICE")
                    .nookEyebrow()
                    .foregroundColor(NookColors.external)
            }
            
            // Title
            Text("Send this to \(payload.serverName)?")
                .font(NookTypography.sheetTitle)
                .foregroundColor(NookColors.ink)
            
            // Body
            Text("This is everything that goes out. Nothing from your documents is included.")
                .font(NookTypography.body)
                .foregroundColor(NookColors.ink62)
            
            // Verbatim Payload Block
            VStack(alignment: .leading, spacing: 8) {
                Text(payload.formattedPayload)
                    .font(NookTypography.code)
                    .foregroundColor(NookColors.ink)
                
                Divider()
                    .background(NookColors.hairline)
                
                HStack(alignment: .top, spacing: 8) {
                    Text("not sent")
                        .font(NookTypography.code)
                        .foregroundColor(NookColors.external)
                    Text(payload.notSentDescription)
                        .font(NookTypography.code)
                        .foregroundColor(NookColors.ink55)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .fill(NookColors.surfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .strokeBorder(NookColors.hairline, lineWidth: 1)
            )
            
            Spacer().frame(height: 4)
            
            // Actions
            VStack(spacing: 8) {
                NookPrimaryButton(title: "Send once") {
                    onAction(.sendOnce)
                }
                
                HStack(spacing: 8) {
                    NookSecondaryButton(title: "Always allow this tool") {
                        onAction(.alwaysAllow)
                    }
                    
                    NookSecondaryButton(title: "Don't") {
                        onAction(.dont)
                    }
                }
            }
        }
        .padding(22)
        .background(NookColors.surface)
        .cornerRadius(NookRadius.sheet)
        .nookSheetShadow()
        .padding(10)
    }
}
