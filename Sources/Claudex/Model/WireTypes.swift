import Foundation

// MARK: - Claude wire types
// GET https://api.anthropic.com/api/oauth/usage
// GET https://api.anthropic.com/api/oauth/profile

enum ClaudeWire {
    struct Usage: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }

        struct Limit: Decodable {
            let kind: String?
            let group: String?
            let percent: Double?
            let severity: String?
            let resetsAt: String?
            let scope: Scope?
            let isActive: Bool?

            enum CodingKeys: String, CodingKey {
                case kind, group, percent, severity, scope
                case resetsAt = "resets_at"
                case isActive = "is_active"
            }

            struct Scope: Decodable {
                let model: Model?
                struct Model: Decodable {
                    let displayName: String?
                    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
                }
            }
        }
    }

    struct Profile: Decodable {
        let account: Account?
        let organization: Organization?

        struct Account: Decodable {
            let uuid: String?
            let fullName: String?
            let email: String?
            let hasClaudeMax: Bool?
            let hasClaudePro: Bool?

            enum CodingKeys: String, CodingKey {
                case uuid
                case fullName = "full_name"
                case email
                case hasClaudeMax = "has_claude_max"
                case hasClaudePro = "has_claude_pro"
            }
        }

        struct Organization: Decodable {
            let rateLimitTier: String?
            let organizationType: String?

            enum CodingKeys: String, CodingKey {
                case rateLimitTier = "rate_limit_tier"
                case organizationType = "organization_type"
            }
        }
    }
}

// MARK: - Codex wire types
// GET https://chatgpt.com/backend-api/wham/usage
// GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits

enum CodexWire {
    struct Usage: Decodable {
        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalLimit]?
        let rateLimitResetCredits: ResetCreditsSummary?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
            case rateLimitResetCredits = "rate_limit_reset_credits"
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAfterSeconds: Double?
            let resetAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAfterSeconds = "reset_after_seconds"
                case resetAt = "reset_at"
            }
        }

        struct AdditionalLimit: Decodable {
            let limitName: String?
            let rateLimit: RateLimit?

            enum CodingKeys: String, CodingKey {
                case limitName = "limit_name"
                case rateLimit = "rate_limit"
            }
        }

        struct ResetCreditsSummary: Decodable {
            let availableCount: Int?
            enum CodingKeys: String, CodingKey { case availableCount = "available_count" }
        }
    }

    struct ResetCredits: Decodable {
        let credits: [Credit]?
        let availableCount: Int?
        let totalEarnedCount: Int?

        enum CodingKeys: String, CodingKey {
            case credits
            case availableCount = "available_count"
            case totalEarnedCount = "total_earned_count"
        }

        struct Credit: Decodable {
            let id: String?
            let title: String?
            let status: String?
            let grantedAt: String?
            let expiresAt: String?

            enum CodingKeys: String, CodingKey {
                case id, title, status
                case grantedAt = "granted_at"
                case expiresAt = "expires_at"
            }
        }
    }
}

// MARK: - Claude credential (keychain JSON payload)

struct ClaudeCredential: Decodable {
    let claudeAiOauth: OAuth?

    enum CodingKeys: String, CodingKey { case claudeAiOauth }

    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?          // epoch millis
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

// MARK: - Codex credential (~/.codex/auth.json)

struct CodexCredential: Decodable {
    let tokens: Tokens?

    struct Tokens: Decodable {
        let accessToken: String
        let accountId: String
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
            case idToken = "id_token"
        }
    }
}

/// The claims we read out of a Codex `id_token` JWT — purely to label the account.
struct CodexIDClaims: Decodable {
    let email: String?
    let name: String?
}
