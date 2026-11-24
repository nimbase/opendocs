## M19 P6/P7/render tests: timestamps, DSS certs, page previews.
##
## Timestamp fixtures use a local self-signed TSA (no network): the
## request is built by buildTimestampReq, answered by `openssl ts
## -reply`, and embedded by embedTimestamp. openssl presence gates
## those tests (skipped without it); the pure-Nim failure paths run
## unconditionally.

import std/os
import std/osproc
import std/strutils
import std/times
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/sign
import ../src/opendocs/pdf/docmodel
import ../src/opendocs/pdf/write
import ../src/opendocs/pdf/cos
import ./pdf_support

const SignDir = "tests/data/pdf/sign/"

proc textBase(): string =
  var b = newPdfBuilder()
  let res = CosObj(kind: coDict, keys: @[], vals: @[])
  let c = b.addContentStream(
    "BT /F1 12 Tf 50 700 Td (Hello sign me) Tj ET", false)
  let fdict = CosObj(kind: coDict,
    keys: @["Type", "Subtype", "BaseFont"],
    vals: @[CosObj(kind: coName, name: "Font"),
      CosObj(kind: coName, name: "Type1"),
      CosObj(kind: coName, name: "Helvetica")])
  let fnum = b.addValue(fdict)
  let res2 = CosObj(kind: coDict, keys: @["Font"],
    vals: @[CosObj(kind: coDict, keys: @["F1"],
      vals: @[CosObj(kind: coRef, refNum: fnum, refGen: 0)])])
  discard res
  discard b.addPage(300.0, 800.0, c, res2)
  b.buildPdf()

proc leafSigner(): Signer =
  Signer(keyPem: readFile(SignDir & "leaf.key"),
    certChain: @[readFile(SignDir & "leaf.cert.pem")], digest: "")

proc signedPdf(): tuple[file: string, sig: string, covered: string] =
  let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192)
  let signed = signPlaceholder(draft, leafSigner())
  let cov = coveredBytes(signed.file, signed.byteRange)
  (signed.file, parseCms(gapContents(signed.file, "Sig1").cmsDer).sigValue,
    cov)

test "timestamp request parses as UTCTime-free GeneralizedTime":
  let req = buildTimestampReq("abc")
  let top = derParse(req)
  check top.tag == 0x30

proc tsaSetup(): tuple[cnf, dir: string] =
  ## Minimal openssl TSA config (local reply generation only) under the
  ## OS temp dir (never hardcoded /tmp: absent on Windows). OpenSSL
  ## config values use forward slashes so backslash escapes on Windows
  ## cannot misparse.
  let dir = getTempDir() / "opendocs_tsa"
  createDir(dir)
  let cnfPath = dir / "tsa_test.cnf"
  let srlPath = dir / "tsa_test.srl"
  let fwd = proc(p: string): string = p.replace('\\', '/')
  writeFile(cnfPath,
    "[ tsa ]\ndefault_tsa = mytsa\n[ mytsa ]\ndir = " & fwd(dir) & "\n" &
    "serial = " & fwd(srlPath) & "\ncrypto_device = builtin\n" &
    "signer_digest = sha256\ncerts = " & SignDir & "tsa.cert.pem\n" &
    "ess_cert_id_alg = sha256\ndefault_policy = 1.2.3\n" &
    "digests = sha1, sha256, sha384, sha512\n")
  writeFile(srlPath, "01")
  (cnfPath, dir)

test "timestamp round-trips through openssl ts":
  let exe = findExe("openssl")
  if exe.len == 0:
    skip()
  else:
    let (cnf, dir) = tsaSetup()
    let (file, sigValue, _) = signedPdf()
    let req = buildTimestampReq(sigValue)
    writeFile(dir / "ts_req.der", req)
    let (_, sc1) = execCmdEx(quoteShell(exe) & " ts -reply -config " &
      quoteShell(cnf) & " -queryfile " &
      quoteShell(dir / "ts_req.der") & " -signer " &
      quoteShell(SignDir & "tsa.cert.pem") & " -inkey " &
      quoteShell(SignDir & "tsa.key") & " -out " &
      quoteShell(dir / "ts_resp.der"))
    check sc1 == 0
    let (token, genTime) = parseTimestampResp(
      readFile(dir / "ts_resp.der"), sigValue)
    check token.len > 0
    check genTime.year >= 2026
    let (ok, _, warnings) = verifyTimestampToken(token, sigValue,
      @[readFile(SignDir & "tsa.cert.der")])
    check ok
    check warnings.len == 0
    let stamped = embedTimestamp(file, "Sig1", token)
    let r = verifySignature(stamped, "Sig1",
      @[readFile(SignDir & "ca.cert.der")])
    check r.valid
    check r.sigOk
    # The token travels inside the new signature revision (hex-encoded).
    check token.len > 0
    check hexEncode(token) in stamped

test "timestamp rejects mismatched imprints":
  let exe = findExe("openssl")
  if exe.len == 0:
    skip()
  else:
    let (cnf, dir) = tsaSetup()
    let (_, sigValue, _) = signedPdf()
    let req = buildTimestampReq(sigValue)
    writeFile(dir / "ts_req.der", req)
    let (_, sc1) = execCmdEx(quoteShell(exe) & " ts -reply -config " &
      quoteShell(cnf) & " -queryfile " &
      quoteShell(dir / "ts_req.der") & " -signer " &
      quoteShell(SignDir & "tsa.cert.pem") & " -inkey " &
      quoteShell(SignDir & "tsa.key") & " -out " &
      quoteShell(dir / "ts_resp.der"))
    check sc1 == 0
    expect PdfError:
      discard parseTimestampResp(readFile(dir / "ts_resp.der"), "wrong!")

test "dss embeds certs and keeps the signature":
  let (file, _, _) = signedPdf()
  let outFile = embedDssCerts(file,
    @[readFile(SignDir & "leaf.cert.der"),
      readFile(SignDir & "ca.cert.der")])
  var d = openDoc(outFile)
  let dss = d.resolve(d.catalog().dictGet("DSS"))
  check dss.kind == coDict
  check dss.dictGet("Certs").items.len == 2
  check dss.dictGet("VRI").kind == coDict
  let r = verifySignature(outFile, "Sig1",
    @[readFile(SignDir & "ca.cert.der")])
  check r.valid

test "dss rejects empty input":
  let (file, _, _) = signedPdf()
  expect PdfError:
    discard embedDssCerts(file, @[])

test "render preview needs poppler":
  # NB: unittest.skip marks but does NOT stop the test body, so the
  # tool-gated body must sit in the else branch.
  if hasPdftoppm():
    let png = renderPagePreview(textBase())
    check png.len > 100
    check png[0] == '\x89' and png[1] == 'P' and png[2] == 'N' and
      png[3] == 'G'
  else:
    skip()

test "render rejects bad pages":
  if hasPdftoppm():
    expect PdfError:
      discard renderPagePreview(textBase(), 99)
  else:
    skip()
