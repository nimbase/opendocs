# PAdES P4b: signature creation and verification (plan, 2026-10-02)

Tier 4. The largest single block in the roadmap, and the only one blocked
on infrastructure that does not exist yet.

## Where P4a stops

`sign.nim` (215 lines) implements P4a and says so at `sign.nim:12-14`:

> Out of scope for P4a: CMS/PKCS#7 build and verification (B-B),
> timestamps, DSS/VRI (B-T/LT/LTA). Those need a CMS dependency and land
> in P4b; until then signature *creation* is external.

Shipped today: `docSignatures` lists `/Sig` field values, and
`verifyByteRangeHash` (`sign.nim:113`) returns the hex SHA-256 of the
`/ByteRange`-covered bytes. `addSignaturePlaceholder` (`sign.nim:122`)
emits an unsigned shell for an external signer to fill. `t_pdf_sign.nim`
has 10 tests covering ranges, tamper detection, duplicate names, and
encrypted rejection.

That is a coherent, honest P4a. P4b closes it.

## The blocking problem: no ASN.1

A CMS SignedData blob is DER-encoded ASN.1. There is no ASN.1 module in
this repo or in any available dependency:

- `nimcypher` has RSA (`rsaPkcs1v15Sign`, `rsaPssSign`), ECDSA
  (`ecdsaSign`), Ed25519, and SHA-1/256/384/512. All the raw crypto.
- No X.509, no DER, no PKCS#7, no PKCS#12 anywhere in `~/.nimble/pkgs2`.
- `jose` (`nimbase/ports/webtokens/jose`) is JSON-based JOSE, not ASN.1.
- libpdfjs reaches for `pkijs` and `@noble/ciphers` in JS.

So P4b means **hand-rolling DER**. That is more tractable than it sounds
for writing (DER is a small TLV grammar) and much less tractable for
reading, where certificate parsing, chain validation, and time parsing
are where correctness actually lives.

**Locked decision: split the work so the DER writer lands first and is
independently testable.** A subtle bug in DER *writing* produces a
malformed CMS that a verifier rejects loudly. A subtle bug in DER
*reading* or chain validation produces a false "valid". The asymmetry
justifies the sequencing.

## Scope

| Item | Level | Priority |
|---|---|---|
| DER encoder | n/a | P1, blocks everything |
| PKCS#7 SignedData build (detached) | B-B | P2 |
| CMS SignedData build (CAdES) | B-B | P3 |
| X.509 certificate parse + chain validation | B-B | P4 |
| Signature verification | B-B | P5 |
| Timestamp (RFC 3161) request and embed | B-T | P6 |
| DSS/VRI gather and embed | B-LT/LTA | P7 |

Defer explicitly:
- **PKCS#12 input.** libpdfjs has a 461-line P12 signer plus
  `pkcs12-kdf.ts`, `triple-des.ts` (350), and `rc2.ts` (246). Triple
  DES is not in nimcypher either. Accept PEM/DER PKCS#8 private keys and
  PKCS#1 RSA keys instead; document it. This is a large saving.
- **Keychain / KMS signers.** Out of scope for a library.
- **CAdES for CAdES.** P3 is CAdES-BES only; CAdES-EP/T/LT/A need the
  timestamp and DSS phases anyway.

## Phase 1: DER encoder (`src/opendocs/pdf/der.nim`, new)

```nim
type
  DerTag* = enum
    dtBoolean, dtInteger, dtBitString, dtOctetString, dtNull,
    dtOid, dtUtf8String, dtSequence, dtSet, dtPrintableString,
    dtIa5String, dtUtcTime, dtGeneralizedTime

proc derLen*(n: int): string
proc derTlv*(tag: DerTag, content: string): string
proc derInt*(v: int64): string
proc derInt*(v: BiggestInt): string
proc derOid*(arcs: openArray[int]): string
proc derBitString*(bytes: string, unusedBits = 0): string
proc derOctetString*(s: string): string
proc derSeq*(parts: varargs[string]): string
proc derSet*(parts: varargs[string]): string
proc derUtcTime*(t: DateTime): string
proc derGeneralizedTime*(t: DateTime): string
```

Requirements: DER definite-length only (BER indefinite lengths are not
needed and are rejected on read); minimal integer encoding (no leading
zero byte unless the high bit requires it); minimal OID arcs; sorted
SET OF members when the schema demands it.

Test against known-good vectors, not against ourselves. Python's
`asn1crypto` or `pyasn1` can generate reference DER for a fixed input;
check those bytes in as a fixture. Also round-trip through
`openssl asn1parse`.

## Phase 2: PKCS#7 SignedData build

```
ContentInfo
  contentType: 1.2.840.113549.1.7.2 (signedData)
  content: [0] EXPLICIT SignedData
    version: 1
    digestAlgorithms: SET OF AlgorithmIdentifier (sha256, 2.16.840.1.101.3.4.2.1)
    encapContentInfo:
      eContentType: 1.2.840.113549.1.7.1 (data)
      # detached: no eContent, only a digest
    certificates: [0] IMPLICIT SET OF Certificate
    signerInfos: SET OF SignerInfo
      version: 1
      issuerAndSerialNumber: IssuerAndSerialNumber
      digestAlgorithm: sha256
      digestEncryptionAlgorithm: rsaEncryption | ecdsa-with-SHA256
      encryptedDigest: OCTET STRING (the signature)
      signerInfo: absent unless authenticated attributes are used
```

Wire-up in `sign.nim`:

```nim
type
  Signer* = ref object of RootObj
    keyPem*: string           ## PKCS#8 or PKCS#1, PEM or DER
    certChain*: seq[string]   ## leaf first, DER or PEM
    digest*: string           ## "sha256" default

proc signPlaceholder*(d: SigDraft, signer: Signer,
    reason = "", location = "", contact = ""): SigDraft
```

This is the payoff: `addSignaturePlaceholder` currently produces bytes
for someone else to sign. `signPlaceholder` fills them in place using the
existing `/ByteRange` machinery (`sign.nim:192-197` already locates and
patches the `/Contents` span). The placeholder becomes optional, an
optimisation for external signers rather than the only path.

`sign.nim` gains a real dependency on `nimcypher/rsa.nim` and
`nimcypher/algos/ecdsa.nim`, both already available.

## Phase 3: CAdES SignedData

Same structure plus `signedAttrs` on the SignerInfo, mandatory
`contentType` and `messageDigest` attributes, and
`signatureValue` unprotected. Per ETSI EN 319 142 the signature is over
the DER encoding of the SignedAttributes, not the content.

```nim
proc signPlaceholderCades*(d: SigDraft, signer: Signer,
    policy = "", ...): SigDraft
```

`sign.nim`'s `verifyByteRangeHash` output is exactly the
`messageDigest` attribute value, so the two fit together cleanly.

## Phase 4: X.509 parse and chain validation

The DER **reader** this time, plus `cert.nim`:

```nim
type
  Cert* = object
    tbs*: TbsCertificate
    sigAlg*: AlgorithmIdentifier
    signature*: string
    raw*: string

  TbsCertificate* = object
    version*: int
    serial*: string
    sigAlg*: AlgorithmIdentifier
    issuer*: Name
    validity*: Validity      ## notBefore, notAfter as DateTime
    subject*: Name
    spki*: SubjectPublicKeyInfo
    extensions*: seq[Extension]

proc parseCert*(der: string): Cert
proc checkChain*(chain: seq[Cert], trust: seq[Cert],
    at: DateTime): seq[string]  ## empty means valid; else reasons
```

Name comparison for issuer/subject matching is **not** byte equality. It
follows RFC 5280 section 6.1: attribute values compare per-type ( PrintableString
and UTF8String with identical contents match; whitespace is folded;
case is folded for DirectoryString types), attribute order is
irrelevant, and multiple RDNs match as a set. Getting this wrong is the
classic cause of chains that verify in one library and fail in another.

Extensions needed: basicConstraints (CA flag, path length), keyUsage,
extendedKeyUsage (id-kp-codeSigning for signing certificates),
subjectKeyIdentifier and authorityKeyIdentifier for chain building, CRL
distribution points and AIA for phase 7.

Algorithm handling: SHA-1 and SHA-256 with RSA, plus ECDSA. SHA-1
signatures must be **reported as weak, not silently accepted**; the plan
adds a `weakAlgorithms*: seq[string]` output rather than a policy that
rejects, because rejection policy belongs to the caller.

## Phase 5: verification

```nim
type
  VerifyResult* = object
    valid*: bool
    covered*: int             ## bytes actually covered by /ByteRange
    digestOk*: bool
    sigOk*: bool
    chainOk*: bool
    signer*: Cert             ## leaf
    trusted*: bool
    signedAt*: DateTime       ## /M
    notBefore*, notAfter*: DateTime
    warnings*: seq[string]

proc verifySignature*(d: var PdfDoc, field: string,
    trust: seq[Cert] = @[]): VerifyResult
```

Checks in order, collecting all failures rather than short-circuiting, so
a caller can see the whole picture:
1. `/ByteRange` present, well-formed, in bounds, and covering the file
   with the `/Contents` gap exactly where it should be.
2. SHA-256 over the covered bytes equals the CMS `messageDigest`.
3. The SignerInfo signature verifies against the leaf's public key.
4. The certificate chain builds to a trust anchor and is valid at the
   signing time.
5. Validity dates and key usage are acceptable.

Document clearly what "valid" means here. This is **cryptographic
integrity plus chain trust**. It is not a statement about document
authenticity beyond that, and it says nothing about whether the content is
truthful. libpdfjs has no verification code at all, so there is no
reference implementation to compare against here.

Note that libpdfjs searches for the **last** `/ByteRange` when patching
(`signatures/placeholder.ts`) to avoid matching pre-existing signatures.
`sign.nim:194` uses `file.find`, which takes the first. The collision
probability is low, because the search pattern is a fixed-width run of
one repeated digit, but `rfind` is strictly correct for multi-signature
documents and costs nothing. Fix it in P2.

Separately: the `/Contents` bounds at `sign.nim:197-200` are found by
scanning for `<` and `>` after the `/ByteRange`. A hex string cannot
contain `>`, so this is safe, but locating the `/Contents` key explicitly
would be more robust than scanning.

## Phase 6: timestamps (B-T)

RFC 3161 over HTTP:
1. Build a `TimeStampReq` (messageImprint = SHA-256 of the signature
   value, certReq = true).
2. POST to the TSA, `Content-Type: application/timestamp-query`.
3. Parse `TimeStampResp`, verify the token (`ContentInfo` /
   `SignedData` with eContentType id-smime-ct-timestamp), check the
   message imprint matches, check `genTime` is within tolerance of the
   document's signing time.
4. Embed as the unsigned attribute `signature-time-stamp`
   (1.2.840.113549.1.9.16.2.14) on the SignerInfo.

Needs an HTTP client. None is in this package's dependencies. Decide
between taking a callback (`proc signPlaceholder*(..., tsa: proc(url, body): string)`)
so the package stays I/O-free, or adding a dependency. **Take the
callback**; it matches the existing "loud failure, no hidden I/O" style
and keeps `opendocs.nimble` unchanged.

## Phase 7: DSS and VRI (B-LT/LTA)

Document Security Store:

```
/DSS in the catalog
  /Certs [0] array of certificate streams
  /OCSPs [1] array of OCSP response streams
  /CRLs  [2] array of CRL streams
  /VRI   /<base32-hex SHA-256 of signature field name> -> /VRI dict
```

Per ETSI EN 319 142-1 the DSS must be an **incremental update** so that
adding validation data does not invalidate the existing signature. This
module already has `beginUpdate`/`finishUpdate` (`write.nim`) doing
exactly that, so this phase composes rather than invents.

Gathering OCSP and CRL responses means more HTTP, again behind the
callback, plus a minimal OCSP request/response builder (`pkijs` has one
in JS) and CRL parsing.

libpdfjs references: `ltv/gatherer.ts` (560), `ltv/dss-builder.ts` (414),
`ltv/vri.ts` (40), `revocation.ts` (469), `aia.ts` (280).

## Phases and gates

| Phase | Output | Gate |
|---|---|---|
| P1 | `der.nim` | byte-exact against reference vectors |
| P2 | `signPlaceholder` | our own output verifies with openssl |
| P3 | CAdES | PAdES conformance fixtures |
| P4 | `cert.nim` | chain validation against real-world chains |
| P5 | `verifySignature` | openssl agrees on every fixture |
| P6 | timestamp | ETSI test vectors |
| P7 | DSS/VRI | incremental update preserves the signature |

**The oracle throughout is OpenSSL**, which is already in CI's toolchain
world and is the reference every PDF signature tool defers to:
`openssl smime -verify`, `openssl cms -verify`, `openssl ts -reply`,
`openssl asn1parse`. A fixture that we sign must verify with OpenSSL, and
a fixture that OpenSSL signs must verify with us. One-directional testing
proves nothing about interop.

Real signature fixtures to vendor: the PDFBox and Apache FOP test
corpora, plus the ETSI PAdES conformance archives. Check licence for each
before vendoring; record provenance in `ATTRIBUTION.md`.

## Risks

- **DER chain validation is where a subtle bug is a silent security
  defect.** A verifier that says "valid" when the chain is broken is
  worse than one that says nothing. When in doubt, return `valid: false`
  with a reason. Fuzz the reader with truncated and bit-flipped DER.
- **No X.509 dependency means no CRL or OCSP *checking* semantics are
  free.** Both need real ASN.1 work in phase 7. Scope P7 carefully or
  defer it; a partial LTV implementation is worse than none.
- **PEM/PKCS#12 scope.** Declining PKCS#12 will surprise users. Document
  it in the README at the same time as P2 ships, not later.
- **HTTP behind a callback** keeps the package dependency-free but makes
  the common case clunky. Provide a worked example in `examples/`.
- **Multi-signature `/ByteRange` matching.** The existing `find` is a
  latent bug; fix it early (P2), because every later phase assumes
  correct placeholder location.
