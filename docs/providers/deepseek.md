# DeepSeek

Tracks a **DeepSeek** account: the prepaid balance from DeepSeek's own API, plus the token spend **DSH**
(DeepSeek Harness) ran through this Mac.

The two halves deliberately come from different places. DeepSeek publishes no usage endpoint — its API is
chat, models, and balance, nothing else — so the balance is all its API can answer. The usage is
*measured* from DSH's local session logs, which record DeepSeek's own per-request token counts.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Balance | Everything left to spend, granted plus topped-up (`$12.34 left`) |
| Balance Breakdown | The same balance split into granted and topped-up credit |
| Today / Yesterday / Last 30 Days | Tokens this Mac sent through DSH and their estimated cost (`$0.42 · 3.1M tokens`) |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

The breakdown row only appears when the account holds both kinds of credit. A balance is a held amount, so
a real zero shows as `$0.00 left` rather than "No data" — the same treatment OpenRouter's balance gets.
DeepSeek bills CNY accounts in yuan, so those balances carry a `¥` mark (`¥70.65`) instead of a dollar
sign. The provider header reads **Active**, or **Balance exhausted** when the account can no longer call
the API.

Days are grouped in your Mac's local time zone, and a period with no recorded usage reads **No data**
rather than a misleading `$0.00 · 0 tokens`.

## Where credentials come from

DeepSeek ships no companion CLI of its own, but DSH does write the key you gave it to
`~/.dsh/.credentials.yaml`. OpenUsage reads that, so **when DSH is already set up here the card works with
nothing to configure**. The lookup order is:

1. `~/.config/openusage/deepseek.json` (or `~/.config/deepseek/key.json`) — the explicit path, editable in
   **Settings → API Keys → DeepSeek**. A key saved here wins over anything discovered, so this is also how
   you override a DSH credential.
2. `~/.dsh/.credentials.yaml` — DSH's own `refs.DEEPSEEK_API_KEY`.
3. The `DEEPSEEK_API_KEY` environment variable.

Only a value found under `refs` is read from DSH's file: it also holds unrelated secrets (a
browser-session grant), and OpenUsage must never hand a different secret to the API. Create your own key
at [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys).

## Where the usage comes from

DSH appends one event log per session at
`~/.dsh/sessions/<project>/session-<uuid>/session.v3.jsonl.zstd`. Every model request lands as an
`assistant/message` record carrying DeepSeek's own `usage` — `inputTokens`, `cacheReadTokens`,
`cacheWriteTokens`, `outputTokens` — plus its own timestamp. OpenUsage decompresses those logs (they are
zstd, which macOS cannot read natively, so a small decoder is bundled) and reads only the usage rows:
never the conversation, and nothing leaves your Mac.

Two details that make the numbers trustworthy:

- **The buckets are disjoint.** DeepSeek's `inputTokens` is the *uncached* prompt — it does not include
  cache reads — and `reasoningTokens` is a subset of the output. So `input + cacheRead + output` is the
  real total, with nothing counted twice.
- **Each request is priced at its own instant.** DeepSeek's rates halve outside its peak window, so a
  day's cost depends on *when* each request ran, not on a daily average. OpenUsage applies the peak or
  off-peak rate per request.

`DSH_HOME` is honored if you relocate DSH's home. Requests are deduplicated by message id, so a resumed or
forked session that replays a transcript cannot count the same request twice.

## Peak and off-peak pricing

DeepSeek's published rates are **peak/off-peak**, and the peak window is UTC **Monday–Friday 01:00–04:00
and 06:00–10:00**; every other hour is off-peak at exactly half the rate.

| Model | | Off-peak | Peak |
|---|---|---|---|
| `deepseek-flash` (V4.1 Flash) | cache hit | $0.003 | $0.006 |
| | cache miss | $0.15 | $0.30 |
| | output | $0.60 | $1.20 |
| `deepseek-v4-pro` | cache hit | $0.022 | $0.044 |
| | cache miss | $0.66 | $1.32 |
| | output | $1.98 | $3.96 |

These rates live in `DeepSeekPricing`, **not** in the shared `pricing_supplement.json`: that file carries
one rate per model, and these rates change with the hour. Re-check the table whenever DeepSeek re-prices —
it is the one place in the app where a rate cannot arrive through the shared pricing update.

The retired names `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` are still accepted by DeepSeek and
served as V4.1 Flash at the Flash price, so they map to that row. From 2026-09-14 `deepseek-v4-pro`
requests are routed to and billed as Flash. A model the table doesn't know is left out of the cost and
flagged with a warning triangle rather than priced at zero.

Estimates represent API-rate value for the traffic this Mac ran. Tokens sent from another Mac, or through
a different client, are not counted — the card says "From your DSH session logs (estimated)" on hover.

## Troubleshooting

- **"No DeepSeek API key"** — no key in the config file, DSH's credentials, or the environment. Add one in
  Settings → API Keys, or set `DEEPSEEK_API_KEY`.
- **"DeepSeek API key rejected"** — the key is wrong, revoked, or belongs to a deleted account. Issue a
  new one and save it in Settings.
- **"Couldn't reach DeepSeek"** — the balance request never completed. The local usage rows still load
  without a network; only the balance needs one.
- **"DeepSeek balance unavailable"** — a `2xx` came back whose body carried no balance to read. Refresh
  again; if it persists, the API changed shape and the card needs an update.
- **"Couldn't read DSH's local session logs"** — DSH is set up but its logs couldn't be read. Check the
  permissions on `~/.dsh`.
- **Spend tiles show "No data"** — DSH logged no requests in that period.
- **A model is missing from the breakdown** — hover the tile's warning triangle to see models the rate
  table doesn't know.

## Under the hood

`GET https://api.deepseek.com/user/balance` with the resolved key as a bearer token gives the balance:
`balance_infos` carries one entry per currency (`total_balance`, `granted_balance`, `topped_up_balance`),
and the top-level `is_available` becomes the header's plan name.

Usage comes from streaming every `session.v3.jsonl.zstd` under `~/.dsh/sessions` whose modification time
falls inside the window, keeping the `assistant/message` records that carry usage, keyed by message id.
Each request contributes its timestamp, the served model, and its token buckets to the shared daily
accumulator, priced at the peak/off-peak tier for that instant.
