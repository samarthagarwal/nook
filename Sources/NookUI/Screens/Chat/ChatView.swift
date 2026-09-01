import SwiftUI
import NookDesign
import NookCore
import NookRuntime

public struct ChatView: View {
    @ObservedObject public var session: AgentSession
    public let runtime: ModelRuntime
    public let onBack: () -> Void
    public let onOpenScope: () -> Void
    public let onOpenAttach: () -> Void
    public let onSelectCitation: (Citation) -> Void
    
    @State private var inputText: String = ""
    @State private var attachedImage: String? = nil
    
    public init(
        session: AgentSession,
        runtime: ModelRuntime,
        onBack: @escaping () -> Void,
        onOpenScope: @escaping () -> Void,
        onOpenAttach: @escaping () -> Void,
        onSelectCitation: @escaping (Citation) -> Void
    ) {
        self.session = session
        self.runtime = runtime
        self.onBack = onBack
        self.onOpenScope = onOpenScope
        self.onOpenAttach = onOpenAttach
        self.onSelectCitation = onSelectCitation
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeaderView
            
            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if session.messages.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(session.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                            
                            if session.isThinking {
                                HStack {
                                    ThinkingDotsView()
                                    Spacer()
                                }
                                .id("thinking-indicator")
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let last = session.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: session.isStreaming) { _, isStreaming in
                    guard !isStreaming, let last = session.messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }

            }
            
            // Scope Line & Composer
            VStack(spacing: 6) {
                // Scope Line
                HStack(spacing: 6) {
                    PrivacyDot(accessibilityText: "Searching locally")
                    Text("Searching \(session.conversation.activeKnowledgeScope.joined(separator: ", ")) · on device")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(NookColors.ink55)
                    Spacer()
                }
                .padding(.horizontal, 20)
                
                // Attached Image Pill if active
                if let img = attachedImage {
                    HStack {
                        ImagePlaceholderView(fileName: img)
                            .frame(width: 44, height: 44)
                        Text(img)
                            .font(NookTypography.fileName)
                            .foregroundColor(NookColors.ink70)
                        Spacer()
                        Button(action: {
                            attachedImage = nil
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(NookColors.ink45)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(NookColors.surface)
                    .cornerRadius(NookRadius.chip)
                    .padding(.horizontal, 18)
                }
                
                // Composer Row
                HStack(spacing: 8) {
                    // Attach Button
                    Button(action: {
                        onOpenAttach()
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(NookColors.ink)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(NookColors.fill))
                    }
                    .buttonStyle(.plain)
                    
                    // Input Text Field
                    HStack {
                        TextField("Ask anything", text: $inputText)
                            .font(NookTypography.userBubble)
                            .foregroundColor(NookColors.ink)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: NookRadius.pill)
                            .fill(NookColors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: NookRadius.pill)
                            .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
                    )
                    
                    // Send Button
                    Button(action: {
                        sendCurrentMessage()
                    }) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(NookColors.inkOnDark)
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(inputText.isEmpty ? NookColors.ink40 : NookColors.ink)
                            )
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            .background(NookColors.paper)
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
    
    // MARK: - Header
    private var chatHeaderView: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                    Text("Nook")
                        .font(NookTypography.body)
                }
                .foregroundColor(NookColors.ink45)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(session.conversation.title)
                    .font(NookTypography.rowTitle)
                    .foregroundColor(NookColors.ink)
                
                HStack(spacing: 4) {
                    PrivacyDot()
                    Text("on device")
                        .font(NookTypography.badge)
                        .foregroundColor(NookColors.ink45)
                }
            }
            
            Spacer()
            
            Button(action: onOpenScope) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(NookColors.ink70)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(NookColors.paper)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(NookColors.hairline),
            alignment: .bottom
        )
    }
    
    // MARK: - Message Row
    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let imgName = message.attachedImageName {
                        ImagePlaceholderView(fileName: imgName)
                            .frame(width: 150, height: 104)
                    }
                    Text(message.content)
                        .font(NookTypography.userBubble)
                        .foregroundColor(NookColors.inkOnDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(NookColors.ink)
                        )
                }
            }
            
        case .localTool:
            if let text = message.localToolText {
                HStack {
                    HStack(spacing: 6) {
                        PrivacyDot(accessibilityText: "Tool executed on device")
                        Text(text)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundColor(NookColors.local)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(NookColors.localSoft)
                    )
                    Spacer()
                }
            }
            
        case .externalTool:
            if let ext = message.externalToolData {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        PrivacyRing(accessibilityText: "External MCP tool executed")
                        Text(ext.toolName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(NookColors.external)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ext.lines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundColor(NookColors.ink70)
                                .lineSpacing(4)
                        }
                    }
                    
                    Text(ext.footer)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundColor(NookColors.external.opacity(0.75))
                        .padding(.top, 2)
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
            
        case .assistant:
            VStack(alignment: .leading, spacing: 11) {
                Text(message.content)
                    .font(NookTypography.assistantBody)
                    .foregroundColor(NookColors.ink)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                
                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FROM YOUR KNOWLEDGE")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        FlowLayout(spacing: 6) {
                            ForEach(message.citations) { citation in
                                Button(action: {
                                    onSelectCitation(citation)
                                }) {
                                    HStack(spacing: 5) {
                                        Text("1")
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundColor(NookColors.local)
                                        Text(citation.label)
                                            .font(.system(size: 11.5, weight: .regular, design: .default))
                                            .foregroundColor(NookColors.ink70)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: NookRadius.chip)
                                            .fill(NookColors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: NookRadius.chip)
                                            .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 20)
        }
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer().frame(height: 20)
            Text("What can I look into?")
                .font(NookTypography.detailTitle)
                .foregroundColor(NookColors.ink)
            
            VStack(spacing: 8) {
                starterPromptButton("What are the biggest risks in this project?")
                starterPromptButton("Does this match the spec? (attach screenshot)", hasAttachment: "screenshot-v4.png")
                starterPromptButton("Check GitHub for open issues about these.")
            }
        }
    }
    
    private func starterPromptButton(_ text: String, hasAttachment: String? = nil) -> some View {
        Button(action: {
            self.inputText = text
            self.attachedImage = hasAttachment
            sendCurrentMessage()
        }) {
            HStack {
                Text(text)
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink70)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NookColors.ink40)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
            )
            .nookCardShadow()
        }
        .buttonStyle(.plain)
    }
    
    private func sendCurrentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let img = attachedImage
        inputText = ""
        attachedImage = nil
        
        Task {
            await session.sendMessage(
                text: text,
                attachedImageName: img,
                runtime: runtime,
                streamHandler: { promptContext, tokenCallback in
                    try await runtime.generateStreaming(
                        promptContext: promptContext,
                        onToken: tokenCallback
                    )
                }
            )
        }
    }
}

// Simple wrapping flow layout for citation chips
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    
    public init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }
    
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeightInRow: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            x += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
            height = max(height, y + maxHeightInRow)
        }
        return CGSize(width: width, height: height)
    }
    
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var maxHeightInRow: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}
