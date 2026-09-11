# WorkBuddy

Tracks the traffic the **WorkBuddy** agent (Tencent's CodeBuddy-family work agent) sends from this Mac.
Everything is read from WorkBuddy's own session transcripts, so there is no login, no key, and no
network call.

This card measures one thing: **how much did this machine actually run through WorkBuddy?** It is a
local traffic report, not a plan balance — WorkBuddy exposes no usage API, so a subscription or credit
meter is out of scope here.

## What it tracks

| Metric | Meaning |
|---|---|
| Today / Yesterday / Last 30 Days | Tokens run through WorkBuddy and their estimated cost (`$1.42 · 812K tokens`) |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

Days are grouped in your Mac's local time zone. A period with no recorded usage reads **No data** rather
than a misleading `$0.00 · 0 tokens`, the same as every other spend-tracking provider.

## Where the data comes from

Use WorkBuddy normally. It writes one append-only JSONL transcript per session under
`~/.workbuddy/projects/<workspace>/<session>.jsonl`, and every model request it makes lands as its own
record carrying the provider's real usage in `providerData.rawUsage` — prompt, completion, and cache-hit
token counts. One request is one record, so OpenUsage sums them rather than estimating anything.

`WORKBUDDY_HOME` is honored if you relocate WorkBuddy's home. Transcripts whose modification time is
older than the window are skipped, so a deep session history stays cheap to rescan. Requests are
deduplicated by their message id, so a resumed or forked session that replays a transcript cannot count
the same request twice.

The card turns itself on by itself: first-run detection looks for at least one request that recorded
tokens. Nothing leaves your Mac.

## Why the dollars are estimated

Token counts are **measured** — they come straight from WorkBuddy's own accounting. The dollars are
**estimated** (that's the ⓘ): OpenUsage prices those tokens at public API rates through the shared
[model pricing](../pricing.md). A WorkBuddy plan does not bill at those rates, so treat the dollars as
what the same traffic would have cost pay-as-you-go — useful for comparing days and models, not a copy
of an invoice.

WorkBuddy reports its prompt count the way the OpenAI-style APIs do: **`prompt_tokens` already includes
the cache hits**. Pricing the whole figure at the input rate would count cached tokens twice, so
OpenUsage bills the non-cached remainder as input and the cached portion at the cache-read rate. The
token total still matches the one WorkBuddy records.

## Troubleshooting

- **"WorkBuddy not detected"** — there are no session transcripts on this Mac. Run a WorkBuddy session
  (or set `WORKBUDDY_HOME` if you relocated its home), then refresh.
- **"Couldn't read WorkBuddy's local session logs"** — transcripts exist but none could be read this
  refresh. Check the permissions on `~/.workbuddy`.
- **Spend tiles show "No data"** — nothing was logged in that period, or the session is older than the
  30-day window.
- **A model is missing from the breakdown** — hover the tile's warning triangle to see models no pricing
  source recognizes; their tokens are counted in the total but priced at zero. WorkBuddy serves several
  in-house models (`hy4-preview`, `deepseek-v4.1-flash`, …) that no public catalog carries yet, so expect
  the warning triangle until they are priced.

## Under the hood

Streaming JSONL read of every `*.jsonl` under `~/.workbuddy/projects`, keeping records whose
`providerData.rawUsage` moved tokens and whose `timestamp` falls inside the window. Each request
contributes its timestamp, served model (`model`, falling back to `requestModelId` for a routed
`auto` request), and the prompt / completion / cache-hit buckets to the shared daily accumulator;
unknown models raise the tile's warning triangle instead of being priced silently.
