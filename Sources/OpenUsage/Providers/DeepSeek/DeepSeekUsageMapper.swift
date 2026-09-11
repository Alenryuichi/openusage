import Foundation

/// Builds the balance rows from DeepSeek's `GET /user/balance` payload.
///
/// DeepSeek publishes no usage or consumption endpoint — this key can only read what is left in the
/// prepaid wallet — so the card answers "how much can I still spend here?", not "what did I spend?".
enum DeepSeekUsageMapper {
    /// One currency's balance, as the API reports it.
    struct Balance: Equatable, Sendable {
        var currency: String
        var total: Double
        var granted: Double
        var toppedUp: Double

        /// The mark to print before the amount. Anything the app can't name falls back to the ISO code
        /// itself, so an unexpected currency still reads unambiguously instead of borrowing "$".
        var symbol: String {
            switch currency.uppercased() {
            case "USD": return "$"
            case "CNY": return "¥"
            default: return currency.uppercased()
            }
        }

        var isUSD: Bool { currency.uppercased() == "USD" }
    }

    /// The account's balances, plus whether the API says the balance still covers calls. Entries whose
    /// amount can't be parsed are dropped at this boundary.
    static func balances(from body: Data) -> (balances: [Balance], isAvailable: Bool?)? {
        guard let object = ProviderParse.jsonObject(body),
              let infos = object["balance_infos"] as? [[String: Any]]
        else { return nil }

        let balances = infos.compactMap { info -> Balance? in
            guard let currency = (info["currency"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                  let total = ProviderParse.number(info["total_balance"])
            else { return nil }
            return Balance(
                currency: currency,
                total: max(0, total),
                granted: max(0, ProviderParse.number(info["granted_balance"]) ?? 0),
                toppedUp: max(0, ProviderParse.number(info["topped_up_balance"]) ?? 0)
            )
        }
        guard !balances.isEmpty else { return nil }
        return (balances, ProviderParse.bool(object["is_available"]))
    }

    /// Total Balance + Balance Breakdown rows for the account's primary currency.
    ///
    /// A balance is a *held amount*, so a real zero is shown ("$0.00 left") rather than "No data" — the
    /// same treatment OpenRouter's balance gets. USD prints through the app's plain dollar formatting;
    /// any other currency (DeepSeek bills CNY accounts in yuan) carries its own mark, so the figure keeps
    /// cents without ever reading as dollars.
    static func lines(for balance: Balance) -> [MetricLine] {
        var lines: [MetricLine] = [
            .values(label: "Total Balance", values: [value(balance.total, in: balance)])
        ]

        // Only report the split when the account actually has both kinds of credit: a granted-only or
        // topped-up-only account reads its whole balance in the total row already.
        if balance.granted > 0, balance.toppedUp > 0 {
            lines.append(.values(label: "Balance Breakdown", values: [
                value(balance.granted, in: balance),
                value(balance.toppedUp, in: balance)
            ]))
        }
        return lines
    }

    private static func value(_ amount: Double, in balance: Balance) -> MetricValue {
        MetricValue(
            number: amount,
            kind: .dollars,
            // `nil` for USD keeps the app's default `$`; only a foreign currency needs naming.
            currencySymbol: balance.isUSD ? nil : balance.symbol
        )
    }
}
