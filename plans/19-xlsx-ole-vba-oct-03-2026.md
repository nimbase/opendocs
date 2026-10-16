# XLSX OLE / CFB and VBA (plan, 2026-10-03)

Tier 3. Phase D from plan 05, unchanged in scope. Self-contained: no
dependency on tiers 1, 2 or 4.

## Locked decisions

- **Read-only CFB.** No writer. Plan 01 section B needs a writer for
  legacy `.doc` output, but that is a separate workstream and sharing the
  reader is enough.
- **Stream listing and bytes only.** VBA macro semantics stay out of
  scope, per plan 05 line 13.
- **`ole2.nim` lives at `src/opendocs/ole2.nim`**, not under `xlsx/`.
  It is a container format, not a spreadsheet concern, and plan 01
  section B needs the same reader for `WordDocument`, `Data` and
  `0Table`/`1Table`. Plan 05's module layout already places it at
  `src/opendocs/ole2.nim` (line 42) for this reason.
- **Reuse `references/msdoc/ole2`.** That Go package is a CFB reader
  *and* writer (283-line reader, 252-line writer), which is a better
  reference than excelize here: excelize has no CFB reader for reading,
  only a writer embedded in `crypt.go`. Note that its `sector.go` and
  `directory.go` are placeholder stubs that say the logic is consolidated
  in `reader.go`, so do not expect sector math there; `reader.go` is the
  whole reader.
- **Encrypted workbooks raise a specific error.** Plan 05 locked this at
  line 29 and `reader.nim:22` already implements it. This plan adds the
  decryption path behind that same check.

## Work items

### 1. CFB reader

Format: MS-CFB. A 512-byte header, a FAT chain for sector allocation, a
directory of 128-byte entries, a MiniFAT for streams under 4096 bytes,
and a DIFAT for large files.

```nim
type
  OleEntry* = object
    name*: string
    kind*: string          ## "storage"/"stream"/"root"
    size*: int64
    startSector*: int32
    clsid*: string
  OleFile* = ref OleFileObj
proc openOle*(path: string): OleFile
proc openOleBytes*(data: string): OleFile
proc oleStmts*(o: OleFile): seq[OleEntry]
proc oleRead*(o: OleFile, name: string): string
proc closeOle*(o: OleFile)
```

- Header validation: magic `D0 CF 11 E0 A1 B1 1A E1`, sector shift
  (9 for v3 / 512B sectors, 12 for v4 / 4096B), mini-sector shift, and
  the FAT/directory sector counts. Reject mismatches rather than trusting
  them.
- **Directory traversal is a red-black tree** whose ordering is by name
  length then uppercase name comparison. Walk it properly; a naive
  left-child-only walk loses entries, and the lost ones are usually the
  macros.
- MiniFAT for streams below the mini-stream cutoff, which is where VBA
  module streams usually live. Getting this wrong yields empty reads for
  exactly the streams that matter.
- **DIFAT** (header array plus DIFAT sectors) for files over 109 FAT
  sectors. `vbaProject.bin` is usually small enough to skip this, but a
  general reader that silently breaks above a threshold is worse than one
  that raises, so implement or reject explicitly.
- **Case-insensitive stream lookup**, matching the zip reader's
  behaviour in `workbook.nim:84`. Producers vary.
- Bound sector chains: a cyclic or over-long FAT chain is a hang and a
  hang is worse than an error. Cap traversed sectors.

### 2. Workbook integration

```nim
type
  XlsxVba* = object
    present*: bool
    streams*: seq[string        ## stream names
    bytes*: seq[string          ## name -> raw bytes
proc getVba*(f: XlsxFile): XlsxVba
proc getVbaStreams*(f: XlsxFile): seq[OleEntry]
```

- The part is at `xl/vbaProject.bin`, already round-tripping untouched
  through `reader.nim`'s spill. `getVba` opens it through `ole2.nim`.
- Streams of interest for later work, by name: `PROJECT`, `PROJECTwm`,
  `_VBA_PROJECT`, `VBA/dir`, `VBA/<module>` for each module, and
  `VBA/_VBA_PROJECT_CUR`. Listing these is the deliverable; interpreting
  the compressed `dir` stream and the module source (which is
  MS-OVBA-compressed, a run-length format distinct from anything in this
  package) is explicitly deferred.
- `sheetPr/@codeName` from plan 17 correlates sheets with the VBA project.
  Read it; do not join on it.
- A `.xlsx` must not contain a `vbaProject.bin` and an `.xlsm` must. Assert
  both directions; a mismatch is a malformed workbook worth reporting
  rather than ignoring.

### 3. Encrypted workbooks

`reader.nim:22` already raises on OLE magic, which satisfies plan 05 line
29. That is the right default and stays. But OLE magic now has a second
meaning: it can be an encrypted OOXML package rather than a legacy one,
and those are *decryptable*.

excelize's `crypt.go` (1,073 lines) does both: `Decrypt` reads
`EncryptionInfo` and `EncryptedPackage` from a CFB via
`richardlehane/mscfb`, then handles ECMA-376 agile (AES, SHA-512, spin
count) and standard (RC4, SHA-1) encryption.

```nim
proc isEncrypted*(data: string): bool
proc decrypt*(data: string, password: string): string   ## raises XlsxError
```

- This requires the CFB reader from item 1 first, which is the ordering
  constraint that makes this plan coherent.
- ECMA-376 agile needs AES-CBC and a hash chain. `nimcypher` is already a
  dependency (`opendocs.nimble:16`), so AES is available. It also needs
  **SHA-512**, and `std/sha1` is the only hash in std, so confirm what
  `nimcypher` provides before assuming.
- **Wrong password must be distinguishable from corrupt input.**
  excelize fails this: 11 of 13 error returns in `crypt.go` are the same
  `ErrWorkbookFileFormat`, so "wrong password" and "not encrypted" are
  indistinguishable. That is a defect worth not copying. `XlsxError`
  should carry a reason, so a caller can prompt for a password.
- **Spin count is a DoS vector.** excelize caps at 100,000 after
  GHSA-jrfj-fhj2-jjvm. Copy that cap; do not honour an unbounded value
  from the file.
- **CFB stream sizes must be capped** before allocating
  (GHSA-x2q3-8cjh-766f), with a version-dependent limit: excelize uses
  `0xFFFFFFFA000` for v4 and `1<<31 - 1` for v3.

Encryption **writing** is not in this plan. It is not in any plan, and
`opendocs/pdf/plans/12-pdf-encrypt-write` is the PDF equivalent. Note
that excelize's `Encrypt` always writes AES-128 standard encryption,
which is weaker than what it reads; do not treat it as a model.

## Reference map

| source | target | notes |
|---|---|---|
| `references/msdoc/ole2/reader.go` (283 lines) | `ole2.nim` | better than excelize; reader + writer |
| `references/excelize/crypt.go` (1,073) | `xlsx/decrypt.nim` | agile + standard ECMA-376 |
| `references/excelize/test/vbaProject.bin` (16K) | fixture | real CFB header, unlike ours |
| `references/excelize/test/encryptAES.xlsx` | fixture | agile, AES |
| `references/excelize/test/encryptSHA1.xlsx` | fixture | standard, SHA-1 |
| `references/excelize/test/encryptSHA512.xlsx` | fixture | standard, SHA-512 |
| `plans/01-doc-docx-indepth.md` lines 58-68 | shared reader | same `ole2` for `.doc` |
| `nimcypher` (existing dep) | AES | confirm SHA-512 availability |

## Phases

1. **P1 `ole2.nim` read side.** Header, FAT, directory tree, MiniFAT,
   DIFAT. Round-trip tests against `references/msdoc`'s fixtures.
2. **P2 VBA stream listing.** `getVba`, `getVbaStreams`, codeName. Uses
   the real `vbaProject.bin` from the excelize reference.
3. **P3 `.xlsx`-has-no-macros assertions**, plus variant coverage from
   plan 18.
4. **P4 decryption.** Only after P1 and P2, and only if the hash
   requirements are satisfiable from existing dependencies.

P4 is separable. If AES/SHA availability or the licensing of the
encryption code proves awkward, stop after P3 and leave decryption
unimplemented; the reader stays complete without it.

## Fixtures

- `ole/vbaProject.bin`: copy the 16 KB file from
  `references/excelize/test/`. Real CFB, real VBA streams. Also serves
  plan 18's `.xlsm` fixture.
- `macro.xlsm`, `macro.xltm`, `macro.xlam`: packages carrying it.
- `macro_bad_magic.xlsm`: `vbaProject.bin` truncated to 8 bytes, which is
  what `t_xlsx.nim:431` does today. Keep it as a negative fixture.
- `macro_empty.xlsm`: valid CFB header with an empty directory.
- `ole/cyclic_fat.bin`: a CFB whose FAT chain loops. Must raise, not hang.
- `ole/v3_and_v4.bin`: both sector sizes, since v4 is 4096 bytes.
- `ole/ministream.bin`: several small streams, to exercise MiniFAT.
- `encrypted/aes.xlsx`, `encrypted/sha1.xlsx`, `encrypted/sha512.xlsx`:
  from the reference, if decryption proceeds.

## Testing

`tests/t_ole.nim` for the container, `tests/t_xlsx_vba.nim` for the
integration.

- Assert the **stream name list** for `vbaProject.bin` against a
  checked-in expectation. That list is the deliverable, so it should be
  pinned exactly, and it will change if a fixture is regenerated.
- Assert `PROJECT` stream bytes round-trip byte-identically.
- Cyclic FAT must raise within a bounded time. Put a timeout on it; a
  hang in CI is worse than a failure.
- MiniFAT vs regular FAT must both be exercised, and a stream small
  enough to be a mini stream read back identically either way.
- Wrong password, corrupt `EncryptionInfo`, and unknown mechanism must
  produce **three distinguishable** errors. This is the assertion excelize
  fails and the reason this plan is worth doing.
- A spin count above the cap must be rejected rather than obeyed.
- An `.xlsx` containing `vbaProject.bin` must raise or warn; state which.

## Risks

- **CFB is a format with a bad history.** Several documented attacks target
  directory traversal and FAT chains. Every length and chain is
  attacker-controlled, so cap everything and prefer raising to guessing.
- **The directory is a red-black tree.** An incorrect walk silently drops
  entries, and the dropped ones are usually the small VBA modules, so the
  failure looks like "no macros found" rather than an error.
- **MiniFAT and regular FAT overlap semantically.** A stream below the
  cutoff is addressed by MiniFAT; reading it with the FAT yields plausible
  garbage. Test both paths deliberately.
- **Decryption without distinguishing wrong-password from corrupt** would
  make encrypted files unopenable in practice, since a caller cannot
  decide whether to prompt. excelize's error collapse is the specific
  thing to avoid.
- **`nimcypher` may not provide SHA-512**, which agile encryption
  requires. Verify before committing to P4 rather than discovering a
  missing dependency afterwards.
- **This plan is small, self-contained and low-risk**, which is why it is
  tier 3. It is also the least valuable per line, since a reader rarely
  needs macro bytes. Its real justification is shared infrastructure for
  plan 01's `.doc` work, and that is worth saying plainly rather than
  overselling VBA support.