import Foundation

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
