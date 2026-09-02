import SwiftUI
import NookDesign
import NookCore

public struct ChatListView: View {
    @Binding public var conversations: [Conversation]
    public let activeTier: ModelTier
    public let onSelectConversation: (Conversation) -> Void
    public let onNewChat: () -> Void
    public let onOpenSettings: () -> Void
    public let onDeleteConversation: (Conversation) -> Void
    
    public init(
        conversations: Binding<[Conversation]>,
        activeTier: ModelTier = ModelTier.recommended,
        onSelectConversation: @escaping (Conversation) -> Void,
        onNewChat: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDeleteConversation: @escaping (Conversation) -> Void
    ) {
        self._conversations = conversations
        self.activeTier = activeTier
        self.onSelectConversation = onSelectConversation
        self.onNewChat = onNewChat
        self.onOpenSettings = onOpenSettings
        self.onDeleteConversation = onDeleteConversation
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nook")
                        .font(NookTypography.tabRootTitle)
                        .foregroundColor(NookColors.ink)
                    
                    ModelBadge(tierName: activeTier.name)
                }
                
                Spacer()
                
                HStack(spacing: 10) {
                    NookIconButton(systemName: "gearshape") {
                        onOpenSettings()
                    }
                    
                    NookIconButton(systemName: "plus", isPrimary: true) {
                        onNewChat()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
            
            // Conversation list
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(conversations) { convo in
                        Button(action: {
                            onSelectConversation(convo)
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(ChatStore.plainText(from: convo.title))
                                        .font(NookTypography.rowTitle)
                                        .foregroundColor(NookColors.ink)
                                    
                                    Spacer()
                                    
                                    Text(convo.whenString)
                                        .font(NookTypography.badge)
                                        .foregroundColor(NookColors.ink45)
                                }
                                
                                Text(ChatStore.plainText(from: convo.snippet))
                                    .font(NookTypography.body)
                                    .foregroundColor(NookColors.ink55)
                                    .lineLimit(2)
                                    .lineSpacing(3)
                                    .multilineTextAlignment(.leading)
                                
                                if !convo.tags.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(convo.tags, id: \.self) { tag in
                                            Text(tag)
                                                .font(NookTypography.badge)
                                                .foregroundColor(NookColors.local)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2.5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: NookRadius.tag)
                                                        .fill(NookColors.localSoft)
                                                )
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                    .fill(NookColors.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: NookRadius.cardLg)
                                    .strokeBorder(NookColors.hairline, lineWidth: 1)
                            )
                            .nookCardShadow()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                onDeleteConversation(convo)
                            } label: {
                                Label("Delete chat", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDeleteConversation(convo)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
}
