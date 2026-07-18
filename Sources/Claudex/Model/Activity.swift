import Foundation

/// One deliberately small, content-free lifecycle event captured by the opt-in Activity
/// Map hook. Raw prompts, responses, command arguments, tool output, full working
/// directories, transcript paths, and provider session identifiers never enter this type.
struct ActivityEvent: Codable, Sendable, Hashable, Identifiable {
    let schemaVersion: Int
    let id: String
    let observedAt: Date
    let provider: Provider
    let accountKey: String
    let sessionKey: String
    let turnKey: String?
    let agentKey: String?
    let projectKey: String
    let projectLabel: String
    let kind: ActivityEventKind
    let toolName: String?
    let toolCategory: ActivityToolCategory?
    let outcome: ActivityOutcome
    let resources: [ActivityResource]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case observedAt = "observed_at"
        case provider
        case accountKey = "account_key"
        case sessionKey = "session_key"
        case turnKey = "turn_key"
        case agentKey = "agent_key"
        case projectKey = "project_key"
        case projectLabel = "project_label"
        case kind
        case toolName = "tool_name"
        case toolCategory = "tool_category"
        case outcome
        case resources
    }
}

enum ActivityEventKind: String, Codable, Sendable, Hashable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case toolCompleted = "tool_completed"
    case toolFailed = "tool_failed"
    case permissionRequested = "permission_requested"
    case subagentStart = "subagent_start"
    case subagentStop = "subagent_stop"
    case other
}

enum ActivityToolCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case read
    case edit
    case search
    case shell
    case web
    case mcp
    case agent
    case interaction
    case other

    var displayName: String {
        switch self {
        case .read: return "Read"
        case .edit: return "Edit"
        case .search: return "Search"
        case .shell: return "Shell"
        case .web: return "Web"
        case .mcp: return "MCP"
        case .agent: return "Agent"
        case .interaction: return "Interaction"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "pencil.line"
        case .search: return "magnifyingglass"
        case .shell: return "terminal"
        case .web: return "globe"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .agent: return "person.2"
        case .interaction: return "hand.raised"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

enum ActivityOutcome: String, Codable, Sendable, Hashable {
    case started
    case succeeded
    case failed
    case requested
    case stopped
    case observed
}

struct ActivityResource: Codable, Sendable, Hashable, Identifiable {
    let path: String
    let action: ActivityResourceAction

    var id: String { "\(action.rawValue):\(path)" }
}

enum ActivityResourceAction: String, Codable, Sendable, Hashable {
    case read
    case write
    case search
}

/// A provider session reconstructed from sanitized lifecycle events. This is a view model,
/// not another persistence format.
struct ActivityConversation: Sendable, Identifiable, Hashable {
    let id: String
    let provider: Provider
    let accountKey: String
    let projectKey: String
    let projectLabel: String
    let startedAt: Date
    let updatedAt: Date
    let events: [ActivityEvent]

    var toolCallCount: Int {
        events.filter { $0.kind == .toolCompleted || $0.kind == .toolFailed }.count
    }

    var permissionCount: Int {
        events.filter { $0.kind == .permissionRequested }.count
    }

    var resourceCount: Int { Set(events.flatMap(\.resources).map(\.path)).count }

    var toolCounts: [ActivityToolCategory: Int] {
        events.reduce(into: [:]) { result, event in
            guard let category = event.toolCategory,
                  event.kind == .toolCompleted || event.kind == .toolFailed || event.kind == .subagentStart
            else { return }
            result[category, default: 0] += 1
        }
    }

    var resourceStats: [String: ActivityResourceStats] {
        events.reduce(into: [:]) { result, event in
            for resource in event.resources {
                var stats = result[resource.path, default: ActivityResourceStats()]
                switch resource.action {
                case .read: stats.reads += 1
                case .write: stats.writes += 1
                case .search: stats.searches += 1
                }
                if let category = event.toolCategory {
                    stats.toolCategories[category, default: 0] += 1
                }
                result[resource.path] = stats
            }
        }
    }
}

struct ActivityResourceStats: Sendable, Hashable {
    var reads = 0
    var writes = 0
    var searches = 0
    var toolCategories: [ActivityToolCategory: Int] = [:]

    var total: Int { reads + writes + searches }
}
