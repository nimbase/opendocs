# PDF encryption writer (plan, 2026-10-02)

Tier 5. Makes the write side symmetric with the read side, which is
already complete.

## Problem

`crypt.nim` (376 lines) implements the full Standard security handler for
*reading*: R2/R3 RC4 with MD5 key derivation, R4 crypt filters, R6
AES-256 with SHA-256 authentication, `/Perms` validation, per-class
`/StmF` and `/StrF` selection. Every one of those algorithms is already
implemented and tested.

None of it can write. There is no forward `computeO` or `computeU`, no
`/Encrypt` dictionary builder, and no per-object encryption on the output
side. Two hard rejections:

```
src/opendocs/pdf/write.nim:411
  M6 rewrite supports unencrypted documents only (file has /Encrypt)
src/opendocs/pdf/write.nim:463
  M6 incremental update supports unencrypted documents only
```

`merge.nim:138` adds a third for encrypted donors. `sign.nim:135` adds a
fourth for encrypted bases.

The README roadmap line 315 claims "encrypt" for this module. It means
decrypt. Plan 13 fixes the wording; this plan makes it true.

## Locked decisions

- **Decrypt-then-encrypt, never encrypt-in-place.** Rewriting an
  encrypted document decrypts every object, writes plain bytes, then the
  final pass encrypts strings and streams per object. There is no path
  that encrypts an already-plain object stream.
- **`/Encrypt` itself is never encrypted.** Per spec, and already handled
  correctly on the read side at `crypt.nim` (`encryptObjNum: -2`).
- **Two output targets only: R4/AESV2 (AES-128) and R6/AESV3 (AES-256).**
  Writing RC4 output would be writing a weak format on purpose. R2/R3
  remain readable, never writable.
- **Encryption is applied at write time, not stored in the object graph.**
  `write.nim`'s serializer stays unaware; a post-serialization pass
  encrypts. This keeps `writeCos` pure and testable.

## Module changes

### `crypt.nim`
The existing `computeO` and `computeU` are recovery routines (they undo
the XOR rounds to *derive a password from* `/O` and `/U`). Writing needs
the forward direction plus key generation.

```nim
type
  EncryptOptions* = object
    userPassword*: string
    ownerPassword*: string    ## "" means same as user
    revision*: int            ## 4 or 6
    permissions*: int         ## /P bits
    encryptMetadata*: bool
    ownerPasswordFromUser*: bool ## /O = /U (single-password mode)

proc makeEncryptDict*(opts: EncryptOptions,
    fileKey: string, idFirst: string): CosObj
proc generateFileKey*(revision: int): string
proc computeO*(ownerPw, userPw, fileKey: string,
    revision: int, idFirst: string): string
proc computeU*(fileKey, idFirst: string): string
proc encryptData*(fileKey: string, objNum, gen: int,
    data: string, opts: EncryptOptions, idFirst: string): string
proc encryptValue*(fileKey: string, objNum, gen: int, val: CosObj,
    opts: EncryptOptions, idFirst: string): CosObj
```

Algorithm 3 (R4, key length from `/Length`, default 128), Algorithms 4-5
(owner and user password, the same 50-iteration MD5 loop `crypt.nim`
already runs in reverse). R6 needs Algorithms 8-10: the SHA-256 based
hash with the hardened 2A/2B routines, the `/U` validation salt, the
AES-256-CBC-no-padding wrapped file key in `/UE`, and `/Perms` as
AES-256-ECB over `"adb" + P (LE32) + FFFFFFFF` with the first byte's
high 4 bits and low 2 bits set. All present in the read path already
(`crypt.nim:296` reads `/Perms`, `crypt.nim` has `sha256raw`,
`aesEcbEnc`, `aesEcbDec`).

Key generation: 32 random bytes from `std/sysrand` for R6, `Length / 8`
for R4. Encryption is per object with the existing `objectKey`
(`crypt.nim:116`), which already salts with the object number and
generation per the spec.

The AES-CBC writer must prepend a random 16-byte IV per object, matching
what `decryptData` already expects.

### `write.nim`
Two additions, both thin.

```nim
proc encryptDocument*(body: string, objs: seq[RawObj],
    opts: EncryptOptions, encryptNum: int): (string, seq[RawObj])
```
Walks the emitted objects, encrypts every `coStr` and every stream's
bytes except the `/Encrypt` dictionary itself, and appends the `/Encrypt`
reference to the trailer. Strings must be encrypted as their *decoded*
bytes and then re-serialised, so this works on the parsed objects before
`writeCos`, not on the serialised text. Hence the signature takes
`seq[RawObj]` rather than `string`.

New public entry points:

```nim
proc rewritePdfEncrypted*(data: string, opts: EncryptOptions,
    password = ""): string
proc finishUpdateEncrypted*(u: var PdfUpdate, opts: EncryptOptions): string
proc buildPdfEncrypted*(b: PdfBuilder, opts: EncryptOptions): string
```

Then lift the two `write.nim` rejections: `rewritePdf` and
`finishUpdate` become thin wrappers that pass through when there is no
`/Encrypt` on input and no `opts`. **Preserve the incremental-signature
guarantee**: an incremental update on a signed document must not
re-encrypt the already-signed bytes, or the signature breaks. Signing and
encryption are mutually exclusive in one incremental chain unless the
encryption change is the final section. Document that constraint.

### `merge.nim`, `sign.nim`
Lift `merge.nim:138` once `copyPage` can clone from a decrypted donor
(the read side already decrypts transparently through `resolve`).
`sign.nim:135` stays: signing an encrypted document is genuinely
meaningless, and the rejection is correct rather than a gap.

## Fixtures

`tests/gen_pdf_fixtures.nim` already contains independent re-derivation
of the crypto math (`md5raw`, `sha256raw`, `rc4s`, `fileKeyR26`) and
generates `m4_rc4.pdf`, `m4_aes.pdf`, `m4_r6.pdf`. That is the oracle.

Add:
- `enc_r4_user.pdf`, `enc_r4_owner.pdf`: R4/AESV2, distinct user and
  owner passwords.
- `enc_r6_user.pdf`, `enc_r6_owner.pdf`: R6/AESV3, same.
- `enc_r6_perms.pdf`: non-default `/P` bits, `/EncryptMetadata false`.
- `enc_r4_cf.pdf`: R4 with explicit `/CF`, `/StmF /StdCF`,
  `/StrF /Identity` (the mixed-class case).
- `enc_metadata_clear.pdf`: `/Metadata` left plaintext, exercising the
  carve-out already implemented at `docmodel.nim:198`.

## Testing

New `tests/t_pdf_encwrite.nim`.

The existing generator's independent re-derivation is the key asset: it
computes `/O`, `/U`, and the file key by a *different* code path than
`crypt.nim`. Cross-checking against it catches implementation errors that
a self-round-trip would not.

Assertions:
- our written file opens with `openPdfPassword`, correct user password,
  and correct owner password, for every fixture above
- **wrong password fails** (an encryptor that accepts anything is the
  classic failure)
- round-trip: write encrypted, read, `rewritePdf`, decrypt cleanly, and
  the resulting text matches the unencrypted original
- per-object keys differ across object numbers (spot-check that
  encrypting the same bytes under two object numbers yields different
  ciphertext)
- `/Perms` decodes to the requested permission bits
- `/ID` is preserved on rewrite
- incremental update: append a page to an encrypted document, verify the
  new page reads and the old content is still correct
- determinism: given a fixed file key, output is byte-identical (inject
  the key rather than generating it, for this test)
- empty strings and empty streams encrypt correctly (IV still required)
- `finishUpdate` output preserves the signed byte range of a
  pre-existing signature, or raises loudly that it cannot (plan 11 has
  the same interaction)

## Risks

- **R6 key derivation is easy to get subtly wrong** and hard to notice,
  because a wrong `/U` makes the file look encrypted and simply not
  openable. The independent generator re-derivation is the defence.
- **Incremental update plus encryption plus signatures is a genuine
  three-way conflict.** All three append to the file; all three change
  what the earlier one committed to. Define the rule once, in
  `write.nim`'s module header, and test the combinations rather than
  documenting them and hoping.
- **Permissions semantics are easy to over-claim.** `/P` bits are
  advisory; a viewer may ignore them. Do not present
  `permissions` support as enforcement.
- Writing only R4 and R6 leaves a gap for callers who need RC4
  compatibility with ancient readers. Say so plainly in the API docs
  rather than offering a weak option quietly.
