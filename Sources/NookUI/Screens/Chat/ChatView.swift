import SwiftUI
import NookDesign
import NookCore
import NookRuntime

public struct ChatView: View {
    @ObservedObject public var session: AgentSession
    @ObservedObject public var runtimeStore: ModelRuntimeStore
    public let skills: [Skill]
    public let onBack: () -> Void
    public let onOpenScope: () -> Void
    public let onOpenAttach: () -> Void
    public let onSelectCitation: (Citation) -> Void
    public let onDelete: () -> Void
    
    @State private var inputText: String = ""
    @State private var attachedImage: String? = nil
    
    public init(
        session: AgentSession,
        runtimeStore: ModelRuntimeStore,
        skills: [Skill] = [],
        onBack: @escaping () -> Void,
        onOpenScope: @escaping () -> Void,
        onOpenAttach: @escaping () -> Void,
        onSelectCitation: @escaping (Citation) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.session = session
        self.runtimeStore = runtimeStore
        self.skills = skills
        self.onBack = onBack
        self.onOpenScope = onOpenScope
        self.onOpenAttach = onOpenAttach
        self.onSelectCitation = onSelectCitation
        self.onDelete = onDelete
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            chatHeaderView
            
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
                .frame(maxHeight: .infinity)
                .onAppear {
                    scrollChatToBottom(proxy: proxy, animated: false)
                }
                .task(id: session.conversation.id) {
                    // LazyVStack needs a layout pass before scroll targets exist.
                    scrollChatToBottom(proxy: proxy, animated: false)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    scrollChatToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: session.messages.count) { _, _ in
                    scrollChatToBottom(proxy: proxy)
                }
                .onChange(of: session.isThinking) { _, isThinking in
                    if isThinking {
                        withAnimation {
                            proxy.scrollTo("thinking-indicator", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: session.isStreaming) { _, isStreaming in
                    guard !isStreaming else {
                        scrollChatToBottom(proxy: proxy)
                        return
                    }
                    scrollChatToBottom(proxy: proxy)
                }
                .onChange(of: session.messages.last?.content) { _, _ in
                    if session.isStreaming {
                        scrollChatToBottom(proxy: proxy)
                    }
                }
            }

            composerView
        }
        .background(NookColors.paper.ignoresSafeArea())
        .sheet(item: Binding(
            get: { session.pendingApproval },
            set: { newValue in
                if newValue == nil, session.pendingApproval != nil {
                    session.resolveApproval(action: .dont)
                } else {
                    session.pendingApproval = newValue
                }
            }
        )) { payload in
            ApprovalSheet(payload: payload) { action in
                session.resolveApproval(action: action)
            }
            .presentationDetents([.fraction(0.65)])
            .presentationDragIndicator(.visible)
            .presentationBackground(NookColors.surface)
            .interactiveDismissDisabled()
        }
    }

    private func scrollChatToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let scroll = {
            if session.isThinking {
                proxy.scrollTo("thinking-indicator", anchor: .bottom)
            } else if let last = session.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        if animated {
            withAnimation { scroll() }
        } else {
            scroll()
        }
    }

    private var slashMatches: [Skill] {
        SkillActivation.autocomplete(prefix: inputText, skills: skills)
    }

    private var knowledgeScopeCaption: String {
        let scope = session.conversation.activeKnowledgeScope
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if scope.isEmpty {
            return "No Knowledge scoped · tap to enable · on device"
        }
        return "Searching \(scope.joined(separator: ", ")) · on device"
    }
    
    private var composerView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                PrivacyDot(accessibilityText: "Searching locally")
                Text(knowledgeScopeCaption)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(NookColors.ink55)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenScope)

            if let skill = skills.first(where: { $0.id == session.conversation.activeSkillId }) {
                HStack(spacing: 8) {
                    Text(skill.name)
                        .font(NookTypography.badge)
                        .foregroundColor(NookColors.local)
                    Text(SkillActivation.slashCommand(for: skill))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(NookColors.ink45)
                    Spacer()
                    Button {
                        session.setActiveSkill(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(NookColors.ink45)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: NookRadius.chip)
                        .fill(NookColors.localSoft)
                )
                .padding(.horizontal, 18)
            }

            if !slashMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slashMatches) { skill in
                        Button {
                            session.setActiveSkill(skill)
                            if let invoked = SkillActivation.parseInvocation(inputText, skills: skills),
                               invoked.skill.id == skill.id {
                                inputText = invoked.remainder
                            } else {
                                inputText = ""
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(NookTypography.rowTitle)
                                        .foregroundColor(NookColors.ink)
                                    Text(SkillActivation.slashCommand(for: skill))
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(NookColors.ink45)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: NookRadius.card)
                        .fill(NookColors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: NookRadius.card)
                        .strokeBorder(NookColors.hairline, lineWidth: 1)
                )
                .padding(.horizontal, 18)
            }

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

            HStack(spacing: 8) {
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

                HStack {
                    TextField(
                        "",
                        text: $inputText,
                        prompt: Text("Ask anything")
                            .font(NookTypography.userBubble)
                            .foregroundColor(NookColors.ink40)
                    )
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

                Button(action: {
                    if session.isStreaming || session.isThinking {
                        session.cancelGeneration()
                        runtimeStore.cancelGeneration()
                    } else {
                        sendCurrentMessage()
                    }
                }) {
                    Image(systemName: (session.isStreaming || session.isThinking) ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(NookColors.inkOnDark)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(
                                    (session.isStreaming || session.isThinking)
                                        ? NookColors.external
                                        : (inputText.isEmpty ? NookColors.ink40 : NookColors.ink)
                                )
                        )
                }
                .disabled(
                    !(session.isStreaming || session.isThinking)
                        && inputText.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .padding(.bottom, 4)
        .background(NookColors.paper)
    }
    
    // MARK: - Header
    private var chatHeaderView: some View {
        HStack(spacing: 8) {
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
            
            VStack(spacing: 2) {
                Text(ChatStore.plainText(from: session.conversation.title))
                    .font(NookTypography.cardSub)
                    .foregroundColor(NookColors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 4) {
                    PrivacyDot()
                    Text("on device")
                        .font(NookTypography.badge)
                        .foregroundColor(NookColors.ink45)
                }
            }
            .frame(maxWidth: .infinity)
            
            HStack(spacing: 10) {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(NookColors.external)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(NookColors.externalSoft))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete chat")
                
                Button(action: onOpenScope) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(NookColors.ink70)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Knowledge scope")
            }
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
                ExternalToolResultCard(execution: ext)
            }
            
        case .assistant:
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    AssistantMessageText(message.content)

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

        if case .downloading = runtimeStore.downloadState {
            runtimeStore.presentStatus(
                "Still downloading \(runtimeStore.displayTierName). You can keep browsing — we'll let you know when it's ready."
            )
            return
        }

        let img = attachedImage
        inputText = ""
        attachedImage = nil

        Task {
            let textToSend = text
            let imageToSend = img
            do {
                try await runtimeStore.prepareForGenerationIfNeeded()
                await session.sendMessage(
                    text: textToSend,
                    attachedImageName: imageToSend,
                    runtime: runtimeStore.runtime,
                    streamHandler: { promptContext, request, toolExecutor, tokenCallback, toolEventCallback in
                        try await runtimeStore.runtime.generateStreaming(
                            promptContext: promptContext,
                            request: request,
                            toolExecutor: toolExecutor,
                            onToken: tokenCallback,
                            onToolEvent: toolEventCallback
                        )
                    }
                )
            } catch {
                inputText = textToSend
                attachedImage = imageToSend
                runtimeStore.presentStatus(runtimeStore.userFacingErrorMessage(for: error))
            }
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
