# CZstd

A vendored, read-only **zstd decoder** — the amalgamated single-file build that zstd itself recommends
for embedding ([Single File Zstandard Libraries](https://github.com/facebook/zstd/tree/dev/build/single_file_libs)).

## Why

The DeepSeek card reads per-request usage and timestamps out of DSH's session event logs, which are
`session.v3.jsonl.zstd`. macOS ships no zstd decoder — `libcompression` exports no zstd symbols, the SDK
has no `zstd.h`, and there is no system `libzstd` — so without this the provider could only report
session-level totals and would have to guess at DeepSeek's peak/off-peak rates, which differ by 2×.

## Provenance

Generated from the official **v1.5.7** release (the `zstd` binary it decodes is v1.5.7 too):

```sh
curl -L https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz | tar xz
cd zstd-1.5.7/build/single_file_libs
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

`zstddeclib.c` is that output verbatim (927 KB, 22,241 lines, zstd 1.5.7). Do not edit it by hand; to
move to a new zstd version, re-run the command above and replace the file, then rebuild and re-run the
DeepSeek scanner tests. `include/CZstd.h` and `include/module.modulemap` are ours — they expose the
header the amalgamation embeds so Swift can import the module.

## What it provides

Only decompression. `ZSTD_decompress` (one-shot, which also handles concatenated frames) and the
streaming API are both available; `DeepSeekSessionDecoder` in the app target is the single call site and
wraps the one-shot path with an explicit error type.
