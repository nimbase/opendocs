# docx read performance — build plan (locked)

## Verdict (from static analysis)

- Direct nimsimd in opendocs: no win. The XML lexer is already SIMD
  (`openparser/private/xml_simd.nim`: AVX2 → SSE2 → scalar dispatch for
  text/attr/name scans, wired into `nextToken`).
- Remaining cost is copies, not scanning (~3× per text byte:
  inflate → seq→string → token → DOM → model).
- Temp spill is RSS containment, not zero-copy: it removes no copy that
  borrowed lexing doesn't already kill, and adds write+VFS+mmap traffic.
  Worth it only as a threshold-gated safety valve for huge docs /
  concurrent parses, with a total disk cap (zip-bomb → disk-fill vector).

## Steps

0. Harness: `examples/docx_perf.nim` — wall time + peak RSS on
   hello.docx, comment.docx (largest fixture), synthetic 5MB document,
   and a concurrent-parses case. Baseline before changes.
1. Borrowed lexing: openparser entry over a borrowed buffer
   (`fromXml(p, len, opts)` or MemFile-for-memory); `parsePartXml`
   lexes the inflate buffer in place. Buffer outlived by archive.
2. Buffer reuse: one reusable inflate destination across parts;
   peak transient ≈ max(part), not Σ(parts). Internal only.
3. Temp spill (threshold-gated, default 64MB inflated; disk cap
   default 512MB): parts inflate straight to
   `spillDir/opendocs-<pid>-<rand>/`, parsed via `fromXml(MemFile)`.
   Unique dir, 0700, `defer` cleanup on all paths, zip-slip-sanitized
   names. Opts on `readDocx(path, opts)`; `spillThresholdBytes`,
   `spillDir`.
4. Input mmap: only as spill's read side; standalone memmap skipped.

## Non-goals

No SAX/DOM bypass, no hand SIMD, no PCLMUL CRC, no parse threading,
no persistent cross-parse temp cache.

## Acceptance

- Small docs within noise of baseline; >threshold synthetic doc has
  RSS ≈ threshold + model; identical output (flatText + block counts).
- Kill-switch: threshold 0 forces spill on fixtures (green);
  unwritable spillDir → clean DocxError; mid-parse exception leaves
  no temp dir.
- `clue test` green; openparser suite 41/41 if touched.

## Results (2026-09-18, same machine)

- Baseline: 4MB XML → 1461ms/parse, 721–736MB peak RSS.
- After steps 1–3: 1444ms, same RSS (noise). The DOM owns ~82% of
  time (lex+DOM 380ms vs 462ms full on 0.85MB XML) and nearly all
  retained memory — safe wins cannot move it.
- Spill path is ~25% faster than memory on big docs (single-pass
  file write vs buffer regrowth) at equal RSS; exact-size inflate
  closed part of the gap in the memory path.
- Conclusion: further headroom needs the excluded work (SAX/DOM
  bypass or DOM diet). Spillover stands as the RSS safety valve and
  the mechanism any future streaming walk would build on.
