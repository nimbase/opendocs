# PDF Merge, Attachments, Signatures

## Merge / split (`pdf/merge.nim`)

```nim
import opendocs/pdf

var a = openDoc(readFile("a.pdf"))
var b = openDoc(readFile("b.pdf"))
writeFile("merged.pdf", mergePdfs(@[readFile("a.pdf"), readFile("b.pdf")]))
writeFile("pages.pdf", extractPages(a, @[0, 2]))
```

- `PageRef(pageRef, mediaBox, resources)` — inherited, materialized.
- `pageRefs(d)`, `copyPage(b, donor, index): newNum` (deep clone, fresh numbers, stream bytes untouched), `extractPages(donor, pages): string` (ordered, repeats allowed), `mergePdfs(donors): string`.

Rejects encrypted inputs. See `examples/example_pdf_merge.nim`, `tests/t_pdf_merge.nim`.

## Attachments (`pdf/attach.nim`)

```nim
import opendocs/pdf
import opendocs/pdf/write

var d = openDoc(readFile("a.pdf"))
for f in embeddedFiles(d):
  echo f.name, " ", f.data.len, " ", f.mime

var b = newPdfBuilder()
let spec = embedFile(b, "note.txt", "hi", desc = "note")
writeFile("with-attach.pdf", b.buildPdf())
```

- `FileAttachment(name, fileName, desc, mime, data)`.
- `guessMime(name)`, `embeddedFiles(d): seq[FileAttachment]` (flat + `/Kids` name tree, `/EF F|UF`, decoded), `embedFile(b, name, data, desc, mime): specNum` (surfaced in `buildPdf` catalog `/Names/EmbeddedFiles`), `embedFileUpdate(u, donor, name, data, desc, mime)` (keep old specs by ref, sorted merge).

See `examples/example_pdf_attach.nim`, `tests/t_pdf_attach.nim`.

## Signatures (`pdf/sign.nim`, `pdf/der.nim`, `pdf/cert.nim`)

```nim
import opendocs/pdf

var d = openDoc(readFile("signed.pdf"))
for s in docSignatures(d):
  echo s.field, " signed=", s.signed, " ", s.byteRange
  echo verifyByteRangeHash(readFile("signed.pdf"), s)

# External signing: reserve a shell, fill it with CMS from any signer.
let draft = addSignaturePlaceholder(readFile("a.pdf"), "Sig1", 8192)
# write draft.file, sign coveredBytes(draft.file, draft.byteRange) externally,
# fillPlaceholder(draft, cmsDer)

# In-repo signing: PKCS#8/PKCS#1/SEC1 key + leaf-first chain (PKCS#12 declined).
let signer = Signer(keyPem: readFile("leaf.key"),
  certChain: @[readFile("leaf.cert.pem")], digest: "")
let signed = signPlaceholder(draft, signer) # or signPlaceholderCades
let r = verifySignature(signed.file, "Sig1", @[readFile("ca.cert.der")])
echo r.valid, " ", r.errors # digestOk/sigOk/chainOk, warnings for sha1
```

- `DocSignature(field, filter, subFilter, byteRange[4], hasByteRange, contents, signed, reason, location, contact, signDate)`, `SigDraft(file, field, byteRange, contentsAt, contentsLen, baseLen)`.
- `docSignatures(d)`, `verifyByteRangeHash(data, sig): hex SHA-256`, `addSignaturePlaceholder(base, fieldName, size, reason, location, contact, subFilter)` (incremental `/Sig/Adobe.PPKLite/adbe.pkcs7.detached` or `ETSI.CAdES.detached`, zeroed `/Contents` hex, patched `/ByteRange`, invisible field, joins/creates `/AcroForm`).
- `buildCms(signer, msg, cades)`, `parseCms(cmsDer)`, `verifySignature(data, field, trust, password)` — collects every failure (digest vs `messageDigest`, crypto, chain to trust) instead of short-circuiting. `valid` needs all three. RSASSA-PSS verifies when salt length equals digest length; EdDSA/DSA fail loudly.
- Correctness note: the signature input is the SignedAttributes SET OF encoding (RFC 5652 5.4), found by differential testing against openssl. Interop is bidirectional: our CMS verifies under `openssl cms -verify`; openssl's CMS (incl. its S/MIME capabilities and `rsaEncryption`-OID sigAlg form) verifies under us.
- Timestamps (P6): `buildTimestampReq`, `parseTimestampResp`, `verifyTimestampToken`, `requestTimestamp` (HTTP stays behind the caller `TsaClient` callback), `embedTimestamp` (unsigned `signature-time-stamp` attribute via incremental update; the original signature still verifies).
- DSS (P7): `embedDssCerts` carries validation certificates only (transport, not LTV: no OCSP/CRL revocation data, so never presented as long-term validation).

See `examples/example_pdf_sign.nim`, `tests/t_pdf_sign.nim`, `t_pdf_signp4b.nim`, `t_pdf_tspdss.nim`, `t_pdf_cert.nim`, `t_pdf_der.nim`.
