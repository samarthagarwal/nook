import SwiftUI
import NookDesign
import NookCore

public struct ConnectionsView: View {
    @ObservedObject public var state: ObservableMCPState
    public let onSelectServer: (MCPServer) -> Void
    public let onAddServer: () -> Void
    
    public init(
        state: ObservableMCPState,
        onSelectServer: @escaping (MCPServer) -> Void,
        onAddServer: @escaping () -> Void
    ) {
        self.state = state
        self.onSelectServer = onSelectServer
        self.onAddServer = onAddServer
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connections")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                
                Spacer()
                
                Button(action: onAddServer) {
                    Text("Add")
                        .font(NookTypography.rowTitle)
                        .foregroundColor(NookColors.local)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Intro
            HStack {
                Text("Outside services Nook can reach. Everything here leaves your device, so it asks first.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                    .lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            
            // Server List
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(state.servers) { server in
                        Button(action: {
                            onSelectServer(server)
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(server.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(NookColors.ink)
                                    
                                    Spacer()
                                    
                                    if server.isConnected {
                                        HStack(spacing: 5) {
                                            PrivacyRing()
                                            Text(server.toolsCountDescription)
                                                .font(NookTypography.badge)
                                                .foregroundColor(NookColors.external)
                                        }
                                    } else {
                                        Text("Not connected")
                                            .font(NookTypography.badge)
                                            .foregroundColor(NookColors.ink40)
                                    }
                                }
                                
                                Text(server.url)
                                    .font(NookTypography.meta)
                                    .foregroundColor(NookColors.ink45)
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
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
}

public struct ServerDetailView: View {
    @State public var server: MCPServer
    public let onBack: () -> Void
    public let onSave: (MCPServer) -> Void
    
    @State private var selectedPolicyIndex: Int = 1 // Consequential
    
    private let policyOptions = MCPApprovalPolicy.allCases.map { $0.rawValue }
    
    public init(server: MCPServer, onBack: @escaping () -> Void, onSave: @escaping (MCPServer) -> Void) {
        self._server = State(initialValue: server)
        self.onBack = onBack
        self.onSave = onSave
        
        let initIndex = MCPApprovalPolicy.allCases.firstIndex(of: server.approvalPolicy) ?? 1
        self._selectedPolicyIndex = State(initialValue: initIndex)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                        Text("Connections")
                            .font(NookTypography.body)
                    }
                    .foregroundColor(NookColors.ink45)
                }
                .buttonStyle(.plain)
                
                Text(server.name)
                    .font(NookTypography.detailTitle)
                    .foregroundColor(NookColors.ink)
                    .padding(.top, 4)
                
                Text("https://\(server.url) · Streamable HTTP · header auth")
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.ink45)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 16)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Segmented Policy Control
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ASK BEFORE SENDING")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        NookSegmentedControl(options: policyOptions, selectedIndex: $selectedPolicyIndex)
                            .onChange(of: selectedPolicyIndex) { _, newIndex in
                                server.approvalPolicy = MCPApprovalPolicy.allCases[newIndex]
                                onSave(server)
                            }

                    }
                    
                    // Tool Rows
                    if !server.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TOOLS FOUND ON THIS SERVER")
                                .nookEyebrow()
                                .foregroundColor(NookColors.ink40)
                            
                            VStack(spacing: 8) {
                                ForEach(server.tools.indices, id: \.self) { idx in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(server.tools[idx].name)
                                                .font(NookTypography.fileName)
                                                .foregroundColor(NookColors.ink)
                                            
                                            Text(server.tools[idx].what)
                                                .font(NookTypography.meta)
                                                .foregroundColor(NookColors.ink55)
                                        }
                                        
                                        Spacer()
                                        
                                        // On = External ochre color
                                        NookToggle(
                                            isOn: $server.tools[idx].isEnabled,
                                            style: .external,
                                            accessibilityLabel: "Enable \(server.tools[idx].name)"
                                        )
                                        .onChange(of: server.tools[idx].isEnabled) { _, _ in
                                            onSave(server)
                                        }

                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: NookRadius.row)
                                            .fill(NookColors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: NookRadius.row)
                                            .strokeBorder(NookColors.hairline, lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
}

@MainActor
public final class ObservableMCPState: ObservableObject {
    @Published public var servers: [MCPServer] = []
    private let client: MCPClient
    
    public init(client: MCPClient) {
        self.client = client
        Task {
            let s = await client.getServers()
            self.servers = s
        }
    }
    
    public func updateServer(_ updated: MCPServer) {
        if let idx = servers.firstIndex(where: { $0.id == updated.id }) {
            servers[idx] = updated
        }
    }
}
