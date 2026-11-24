# OLE2 Compound Files

Implementation: `src/opendocs/ole2.nim` (standalone, no opendocs
imports). MS-CFB read-only container reader, shared plumbing for the
XLSX VBA integration now and the future `.doc` reader later.

```nim
import opendocs/ole2

let o = openOleBytes(bytes) # or openOle(path)
defer: o.closeOle()
for e in o.entries(): # storage paths: "VBA/dir"
  echo e.kind, " ", e.name, " ", e.size
let code = o.readStream("VBA/dir") # case-insensitive
check o.contains("PROJECT")
```

- `openOleBytes(data: openArray[byte]) / openOle(path): OleFile` —
  full header validation (signature, version 3/4, sector shift, byte
  order), DIFAT chaining, FAT load, directory walk, MiniFAT + mini
  stream reassembly. Every structural defect raises `OleError`.
- `entries(o): seq[OleEntry]` — in-order red-black walk (root
  included); freed slots skipped without descending. Names carry
  storage paths (`VBA/dir`).
- `readStream(o, name): seq[byte]` — case-insensitive; mini vs
  regular table chosen by the header cutoff, never the caller. Short
  chains fail loudly (truncated).
- `contains(o, name): bool` — stream existence probe.
- `OleEntry(name, kind, size, startSector, clsid)` — `clsid` as a
  canonical GUID string, "" when all zero.

## Bounds (all attacker-controlled)

- Every sector number validated `< sectorCount` before use.
- Every chain (FAT, MiniFAT, DIFAT, directory, stream, mini) capped
  at `sectorCount + 1` steps: cycles raise deterministically, no
  timeouts needed.
- Streams capped at 64 MB before allocating (zip-guard parity).

## Heuristics

- Names decode UTF-16LE with U+FFFD substitution for lone
  surrogates: a bad name must not brick the container.
- Directory-name lookups are case-insensitive (Unicode fold).

See `tests/t_ole.nim` (12/12: real `vbaProject.bin` inventory pin,
MiniFAT decode, synthetic v3/v4/DIFAT/cyclic/truncated inputs).
