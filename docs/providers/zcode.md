# Zcode

Tracks the traffic the **Zcode** CLI sends from this Mac — the requests it makes through its built-in
Z.ai coding plan. Everything is read from Zcode's own local accounting database, so there is no login,
no key, and no network call.

This card measures one thing: **how much did this machine actually run through Zcode?** It is a local
traffic report, not a subscription balance — for Z.ai plan quotas (Session / Weekly / Web Searches), see
the [Z.ai](zai.md) card. The two complement each other rather than overlap.

## What it tracks

| Metric | Meaning |
|---|---|
| Today / Yesterday / Last 30 Days | Tokens run through Zcode and their estimated cost (`$4.08 · 1.2M tokens`) |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

Days are grouped in your Mac's local time zone. A period with no recorded usage reads **No data** rather
than a misleading `$0.00 · 0 tokens`, the same as every other spend-tracking provider.

## Where the data comes from

Use Zcode normally. It logs one row per model request to `~/.zcode/cli/db/db.sqlite` (the `model_usage`
table) with the full per-request token breakdown. OpenUsage opens that database **read-only** and
aggregates it by day. `ZCODE_HOME` is honored if you relocate Zcode's home; every `*.sqlite` file under
`<home>/cli/db` is read, so a future sharded store works without an update.

The card turns itself on by itself: first-run detection looks for at least one request that recorded
tokens in that database. Nothing leaves your Mac.

## Why the dollars are estimated

Token counts are **measured** — they come straight from Zcode's own accounting. The dollars are
**estimated** (that's the ⓘ): OpenUsage prices those tokens at Z.ai's public per-million rates through
the shared [model pricing](../pricing.md). Subscription and off-peak plans don't bill at those rates, so
treat the dollars as what the same traffic would have cost pay-as-you-go — useful for comparing days and
models, not a copy of an invoice.

Zcode reports its input count the way the Anthropic-style APIs do: **`input_tokens` already includes
cache reads and cache writes**. Pricing the whole figure at the input rate would count cached tokens
twice, so OpenUsage bills the non-cached remainder as input and the cached portion at the cache-read
rate. The token total still matches the one Zcode records.

## Troubleshooting

- **"Zcode not detected"** — there is no Zcode database with any token usage on this Mac. Run a Zcode
  session (or set `ZCODE_HOME` if you relocated its home), then refresh.
- **"Couldn't read Zcode's local database"** — the database exists but couldn't be read this refresh.
  Quit Zcode and refresh; if it persists, check the permissions on `~/.zcode`.
- **Spend tiles show "No data"** — nothing was logged in that period. Days more than 30 days old fall
  outside the window.
- **A model is missing from the breakdown** — hover the row's warning triangle to see models no pricing
  source recognizes; their tokens are counted in the total but priced at zero.

## Under the hood

Read-only `sqlite3` against every `*.sqlite` under `~/.zcode/cli/db`, selecting `model_usage` rows whose
`started_at` is inside the tile window and whose combined token buckets are non-zero (an errored or
cancelled request logs zeros). Each row contributes `started_at`, `model_id`, and the input / output /
cache-read / cache-creation buckets to the shared daily accumulator; unknown models raise the tile's
warning triangle instead of being priced silently.
