import SwiftUI
import NookDesign
import NookCore

public struct AttachSheet: View {
    public let onSelectAttachment: (String) -> Void
    public let onClose: () -> Void
    
    public init(onSelectAttachment: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onSelectAttachment = onSelectAttachment
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Attach to chat")
                    .font(NookTypography.sheetTitle)
                    .foregroundColor(NookColors.ink)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NookColors.ink70)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(NookColors.fill))
                }
                .buttonStyle(.plain)
            }
            
            VStack(spacing: 8) {
                attachRow(title: "Screenshot", sub: "Read on device by the vision model", icon: "photo", fileName: "screenshot-v4.png")
                attachRow(title: "Take a photo", sub: "Receipts, whiteboards, pages", icon: "camera", fileName: "receipt-camera.jpg")
                attachRow(title: "A file", sub: "Added to this chat only", icon: "doc", fileName: "spec-addendum.pdf")
                attachRow(title: "A previous conversation", sub: "Attach an earlier chat as context", icon: "bubble.left.and.bubble.right", fileName: "chat:London-trip")
            }
            
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NookColors.surface)
    }
    
    private func attachRow(title: String, sub: String, icon: String, fileName: String) -> some View {
        Button(action: {
            onSelectAttachment(fileName)
            onClose()
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(NookColors.ink70)
                    .frame(width: 28)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NookTypography.rowTitle)
                        .foregroundColor(NookColors.ink)
                    Text(sub)
                        .font(NookTypography.meta)
                        .foregroundColor(NookColors.ink55)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NookColors.ink40)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .fill(NookColors.surfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .strokeBorder(NookColors.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct ScopeSheet: View {
    @ObservedObject private var session: AgentSession
    public let availableCollections: [String]
    public let onClose: () -> Void
    
    public init(
        session: AgentSession,
        availableCollections: [String] = [],
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.availableCollections = availableCollections
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("What can this chat see?")
                        .font(NookTypography.display21)
                        .foregroundColor(NookColors.ink)
                    Text(
                        availableCollections.isEmpty
                            ? "Collections you add in Knowledge appear here."
                            : "Only the collections you tick are searched."
                    )
                        .font(NookTypography.body)
                        .foregroundColor(NookColors.ink62)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NookColors.ink70)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(NookColors.fill))
                }
                .buttonStyle(.plain)
            }
            
            if availableCollections.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 12)

                    Image(systemName: "books.vertical")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(NookColors.ink40)

                    VStack(spacing: 8) {
                        Text("No knowledge yet")
                            .font(NookTypography.cardTitleSerif)
                            .foregroundColor(NookColors.ink)

                        Text("Add a collection under Knowledge, then import Markdown. This chat will be able to search it here.")
                            .font(NookTypography.body)
                            .foregroundColor(NookColors.ink62)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }

                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 8) {
                    ForEach(availableCollections, id: \.self) { coll in
                        HStack {
                            Text(coll)
                                .font(NookTypography.rowTitle)
                                .foregroundColor(NookColors.ink)
                            Spacer()
                            NookToggle(
                                isOn: Binding(
                                    get: { session.conversation.activeKnowledgeScope.contains(coll) },
                                    set: { newValue in
                                        setCollection(coll, included: newValue)
                                    }
                                ),
                                style: .local,
                                accessibilityLabel: "Include \(coll)"
                            )
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .fill(NookColors.surfaceSunken)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .strokeBorder(NookColors.hairline, lineWidth: 1)
                        )
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NookColors.surface)
    }
    
    private func setCollection(_ name: String, included: Bool) {
        var conversation = session.conversation
        var scope = conversation.activeKnowledgeScope
        if included {
            if !scope.contains(name) {
                scope.append(name)
            }
        } else {
            scope.removeAll { $0 == name }
        }
        conversation.activeKnowledgeScope = scope
        session.conversation = conversation
        session.persistConversationMetadata()
    }
}
