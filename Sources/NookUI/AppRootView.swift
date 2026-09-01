import SwiftUI
import NookDesign
import NookCore
import NookRuntime

public struct AppRootView: View {
    @State private var isOnboardingComplete: Bool = false
    @State private var selectedTab: NookTab = .chat
    @State private var activeTier: ModelTier = ModelTier.standardTiers[0]
    
    // Core Engine Instances
    @StateObject private var knowledgeState: ObservableKnowledgeEngine
    @StateObject private var skillState: ObservableSkillManager
    @StateObject private var mcpState: ObservableMCPState
    @StateObject private var memoryState: ObservableMemoryState
    
    private let knowledgeEngine: KnowledgeEngine
    private let memoryEngine: MemoryEngine
    private let skillManager: SkillManager
    private let toolRegistry: ToolRegistry
    private let mcpClient: MCPClient
    private let runtime: ModelRuntime
    
    // Navigation / Detail States
    @State private var conversations: [Conversation] = []
    @State private var activeSession: AgentSession? = nil
    @State private var selectedCollection: KnowledgeCollection? = nil
    @State private var selectedSkill: Skill? = nil
    @State private var selectedServer: MCPServer? = nil
    
    // Sheet Presentations
    @State private var isSettingsOpen: Bool = false
    @State private var isModelsOpen: Bool = false
    @State private var isPaywallOpen: Bool = false
    @State private var activeCitation: Citation? = nil
    @State private var isAttachSheetOpen: Bool = false
    @State private var isScopeSheetOpen: Bool = false
    @State private var activeToast: String? = nil
    
    public init(
        knowledgeEngine: KnowledgeEngine = KnowledgeEngine(),
        memoryEngine: MemoryEngine = MemoryEngine(),
        skillManager: SkillManager = SkillManager(),
        toolRegistry: ToolRegistry = ToolRegistry(),
        mcpClient: MCPClient = MCPClient(),
        runtime: ModelRuntime = ModelRuntimeFactory.make(activeTier: ModelTier.standardTiers[0])
    ) {
        self.knowledgeEngine = knowledgeEngine
        self.memoryEngine = memoryEngine
        self.skillManager = skillManager
        self.toolRegistry = toolRegistry
        self.mcpClient = mcpClient
        self.runtime = runtime
        
        _knowledgeState = StateObject(wrappedValue: ObservableKnowledgeEngine(engine: knowledgeEngine))
        _skillState = StateObject(wrappedValue: ObservableSkillManager(manager: skillManager))
        _mcpState = StateObject(wrappedValue: ObservableMCPState(client: mcpClient))
        _memoryState = StateObject(wrappedValue: ObservableMemoryState(engine: memoryEngine))
    }
    
    public var body: some View {
        ZStack {
            NookColors.paper.ignoresSafeArea()
            
            if !isOnboardingComplete {
                OnboardingView(
                    downloadModel: { tier, progress in
                        try await self.runtime.downloadModel(tier: tier, progressHandler: progress)
                    },
                    onComplete: { chosenTier in
                        self.activeTier = chosenTier
                        self.isOnboardingComplete = true
                        startNewChat()
                    }
                )
            } else {
                mainContentView
            }
            
            // Toast Overlay
            if let toast = activeToast ?? activeSession?.toastMessage {
                VStack {
                    Spacer()
                    ToastOverlay(message: toast)
                }
                .transition(.opacity)
                .animation(.linear(duration: 0.2), value: toast)
            }
        }
        .onChange(of: activeTier) { _, newTier in
            guard isOnboardingComplete else { return }
            Task {
                try? await runtime.downloadModel(tier: newTier) { _ in }
            }
        }
        .onAppear {
            setupInitialConversations()
            print("[AppRootView] App launched. Runtime: \(type(of: runtime)) (\(MLXPlatformSupport.runtimeLabel)). DownloadState: \(runtime.downloadState)")
            // If onboarding is already complete (e.g. dev mode), trigger model download
            // immediately so it's ready before the user sends their first message.
            if isOnboardingComplete && runtime.downloadState == .notDownloaded {
                let tier = activeTier
                Task.detached(priority: .userInitiated) {
                    print("[AppRootView] Pre-loading model for tier: \(tier.name)")
                    try? await runtime.downloadModel(tier: tier) { progress in
                        print("[AppRootView] Pre-load progress: \(Int(progress * 100))%")
                    }
                    print("[AppRootView] Pre-load complete. Model ready.")
                }
            }
        }
    }
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            ZStack {
                // Tab 1: Chat Root or Active Chat Detail
                if selectedTab == .chat {
                    if let session = activeSession {
                        ChatView(
                            session: session,
                            runtime: runtime,
                            onBack: {
                                self.activeSession = nil
                            },
                            onOpenScope: {
                                self.isScopeSheetOpen = true
                            },
                            onOpenAttach: {
                                self.isAttachSheetOpen = true
                            },
                            onSelectCitation: { citation in
                                self.activeCitation = citation
                            }
                        )
                    } else {
                        ChatListView(
                            conversations: $conversations,
                            activeTier: activeTier,
                            onSelectConversation: { convo in
                                openConversation(convo)
                            },
                            onNewChat: {
                                startNewChat()
                            },
                            onOpenSettings: {
                                self.isSettingsOpen = true
                            }
                        )
                    }
                }
                
                // Tab 2: Knowledge
                if selectedTab == .knowledge {
                    if let coll = selectedCollection {
                        CollectionDetailView(
                            collection: coll,
                            documents: [
                                KnowledgeDocument(collectionId: coll.id, name: "alpha-spec-v4.pdf", meta: "42 pages", status: "Indexed"),
                                KnowledgeDocument(collectionId: coll.id, name: "risk-register.pdf", meta: "6 pages", status: "Indexed"),
                                KnowledgeDocument(collectionId: coll.id, name: "retro-notes.md", meta: "2,100 words", status: "Indexed"),
                                KnowledgeDocument(collectionId: coll.id, name: "vendor-contract.docx", meta: "18 pages", status: "Extracting 62%", progressPct: 62)
                            ],
                            onBack: {
                                self.selectedCollection = nil
                            },
                            onStartChat: {
                                self.selectedCollection = nil
                                self.selectedTab = .chat
                                startNewChat(scopedTo: [coll.name])
                            }
                        )
                    } else {
                        KnowledgeView(
                            knowledgeEngineState: knowledgeState,
                            onSelectCollection: { coll in
                                self.selectedCollection = coll
                            },
                            onAddCollection: {
                                showToast("Document picker opened on device")
                            }
                        )
                    }
                }
                
                // Tab 3: Skills
                if selectedTab == .skills {
                    if let skill = selectedSkill {
                        SkillDetailView(
                            skill: skill,
                            onBack: {
                                self.selectedSkill = nil
                            },
                            onToggleSkill: { updated in
                                skillState.updateSkill(updated)
                            }
                        )
                    } else {
                        SkillsView(
                            state: skillState,
                            onSelectSkill: { skill in
                                self.selectedSkill = skill
                            },
                            onImportSkill: {
                                showToast("SKILL.md package imported")
                            }
                        )
                    }
                }
                
                // Tab 4: Connect (MCP)
                if selectedTab == .connect {
                    if let server = selectedServer {
                        ServerDetailView(
                            server: server,
                            onBack: {
                                self.selectedServer = nil
                            },
                            onSave: { updated in
                                mcpState.updateServer(updated)
                            }
                        )
                    } else {
                        ConnectionsView(
                            state: mcpState,
                            onSelectServer: { server in
                                self.selectedServer = server
                            },
                            onAddServer: {
                                showToast("Add MCP server configuration")
                            }
                        )
                    }
                }
                
                // Tab 5: Memory
                if selectedTab == .memory {
                    MemoryView(
                        state: memoryState,
                        onOpenSourceChat: { source in
                            self.selectedTab = .chat
                            if let first = conversations.first {
                                openConversation(first)
                            }
                        },
                        onForgetMemory: { item in
                            memoryState.forget(item: item)
                            showToast("Forgotten. The chat itself is untouched.")
                        }
                    )
                }
            }
            
            // Tab Bar: Hidden on Chat Detail view
            if activeSession == nil {
                NookTabBar(selectedTab: $selectedTab)
            }
        }
        // Sheets
        .sheet(isPresented: $isSettingsOpen) {
            SettingsView(
                activeTier: $activeTier,
                onOpenModels: {
                    self.isSettingsOpen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.isModelsOpen = true
                    }
                },
                onOpenPaywall: {
                    self.isSettingsOpen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.isPaywallOpen = true
                    }
                },
                onRebuildIndexes: {
                    self.isSettingsOpen = false
                    showToast("Rebuilt from your chats. Nothing you wrote was deleted.")
                },
                onExportData: {
                    self.isSettingsOpen = false
                    showToast("Export package saved locally.")
                },
                onClose: {
                    self.isSettingsOpen = false
                }
            )
        }
        .sheet(isPresented: $isModelsOpen) {
            ModelsView(activeTier: $activeTier) {
                self.isModelsOpen = false
            }
        }
        .sheet(isPresented: $isPaywallOpen) {
            PaywallView(
                onClose: {
                    self.isPaywallOpen = false
                },
                onPurchase: {
                    self.isPaywallOpen = false
                    showToast("Nook Pro activated.")
                }
            )
        }
        .sheet(item: $activeCitation) { citation in
            CitationSheet(citation: citation) {
                self.activeCitation = nil
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isAttachSheetOpen) {
            AttachSheet(
                onSelectAttachment: { attachment in
                    showToast("Attached \(attachment)")
                },
                onClose: {
                    self.isAttachSheetOpen = false
                }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isScopeSheetOpen) {
            if let session = activeSession {
                ScopeSheet(
                    activeScope: Binding(
                        get: { session.conversation.activeKnowledgeScope },
                        set: { session.conversation.activeKnowledgeScope = $0 }
                    ),
                    onClose: {
                        self.isScopeSheetOpen = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(item: Binding<OutgoingApprovalPayload?>(
            get: { activeSession?.pendingApproval },
            set: { activeSession?.pendingApproval = $0 }
        )) { payload in
            ApprovalSheet(payload: payload) { action in
                activeSession?.resolveApproval(action: action)
            }
            .presentationDetents([.fraction(0.65)])
        }
    }
    
    private func setupInitialConversations() {
        conversations = [
            Conversation(
                id: "c1",
                title: "Project Alpha review",
                whenString: "now",
                snippet: "Three risks come up repeatedly across your project…",
                tags: ["Project Alpha"],
                activeKnowledgeScope: ["Project Alpha"]
            ),
            Conversation(
                id: "c2",
                title: "London trip debrief",
                whenString: "25 Aug",
                snippet: "Sarah recommended DuckDB for the local analytics layer.",
                tags: []
            ),
            Conversation(
                id: "c3",
                title: "Dinner planning",
                whenString: "24 Aug",
                snippet: "The bánh mì place on Exmouth Market, apparently worth the queue.",
                tags: []
            ),
            Conversation(
                id: "c4",
                title: "Receipts, July",
                whenString: "12 Aug",
                snippet: "Filed eleven receipts into Personal. Two need a category.",
                tags: ["Personal"]
            )
        ]
    }
    
    private func openConversation(_ convo: Conversation) {
        let session = AgentSession(
            conversation: convo,
            knowledgeEngine: knowledgeEngine,
            memoryEngine: memoryEngine,
            skillManager: skillManager,
            toolRegistry: toolRegistry,
            mcpClient: mcpClient
        )
        self.activeSession = session
    }
    
    private func startNewChat(scopedTo: [String] = ["Project Alpha"]) {
        let newConvo = Conversation(
            title: "New chat",
            whenString: "now",
            snippet: "Ask anything",
            tags: scopedTo,
            activeKnowledgeScope: scopedTo
        )
        conversations.insert(newConvo, at: 0)
        openConversation(newConvo)
    }
    
    private func showToast(_ message: String) {
        self.activeToast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.activeToast == message {
                self.activeToast = nil
            }
        }
    }
}

extension OutgoingApprovalPayload: Identifiable {
    public var id: String { toolName + serverUrl }
}
