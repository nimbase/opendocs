## M19 P5 tests: CMS build, in-place sign, verify, openssl interop.
##
## openssl(1) is the behavioral oracle here (already in CI's toolchain):
## our CMS must verify under `openssl cms -verify`, and openssl's CMS
## must verify under `verifySignature`. Both directions shell out only
## when openssl is present, otherwise they skip; every assertion that
## does not need openssl runs unconditionally.

import std/os
import std/osproc
import std/strutils
import std/times
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/sign
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

proc cmsOf(file: string, at, len: int): string =
  ## Raw CMS bytes from a /Contents hex span (zero padding stripped).
  let h = file[at ..< at + len - 1]
  var e = h.len
  while e > 2 and h[e - 2 ..< e] == "00":
    e -= 2
  hexDecode(h[0 ..< e])

test "buildCms parses with matching signer":
  let cms = buildCms(leafSigner(), "hello", false)
  let parsed = parseCms(cms)
  check parsed.digestName == "sha256"
  check not parsed.hasAttrs
  check parsed.certs.len == 1
  check certLabel(parsed.certs[0]) == "Test Signer"
  check parsed.messageDigest == ""
  check parsed.sigValue.len == 256

test "cades build carries signed attributes":
  let cms = buildCms(leafSigner(), "hello", true)
  let parsed = parseCms(cms)
  check parsed.hasAttrs
  check parsed.messageDigest == hashBytes("sha256", "hello")

test "sign + verify round-trips":
  let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192)
  let signed = signPlaceholder(draft, leafSigner()).file
  let r = verifySignature(signed, "Sig1",
    @[readFile(SignDir & "ca.cert.der")])
  check r.valid
  check r.digestOk
  check r.sigOk
  check r.chainOk
  check r.trusted
  check r.errors.len == 0
  check r.hasSignedAt
  check certLabel(r.signer) == "Test Signer"

test "cades sign + verify round-trips":
  let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192,
    subFilter = "ETSI.CAdES.detached")
  let signed = signPlaceholderCades(draft, leafSigner()).file
  let r = verifySignature(signed, "Sig1",
    @[readFile(SignDir & "ca.cert.der")])
  check r.valid
  check r.digestOk and r.sigOk and r.chainOk

test "ec sign + verify round-trips":
  let draft = addSignaturePlaceholder(textBase(), "SigEC", 8192)
  let ecSigner = Signer(keyPem: readFile(SignDir & "ec.key"),
    certChain: @[readFile(SignDir & "ec.cert.pem")], digest: "")
  let signed = signPlaceholder(draft, ecSigner).file
  let r = verifySignature(signed, "SigEC",
    @[readFile(SignDir & "ec.cert.der")])
  check r.valid
  check r.digestOk and r.sigOk and r.chainOk

test "tampered bytes fail integrity, keep the chain":
  let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192)
  var file = signPlaceholder(draft, leafSigner()).file
  let at = file.find("(Hello sign me)")
  check at >= 0
  file[at + 1] = 'X'
  let r = verifySignature(file, "Sig1",
    @[readFile(SignDir & "ca.cert.der")])
  check not r.valid
  check not r.sigOk
  check r.chainOk # chain never touches content bytes

test "unknown field and no trust fail loudly":
  let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192)
  let signed = signPlaceholder(draft, leafSigner()).file
  let r1 = verifySignature(signed, "Missing",
    @[readFile(SignDir & "ca.cert.der")])
  check not r1.valid
  check r1.errors.len > 0
  let r2 = verifySignature(signed, "Sig1")
  check not r2.valid
  check not r2.chainOk
  check r2.sigOk

test "openssl verifies our cms":
  let exe = findExe("openssl")
  if exe.len == 0:
    skip()
  else:
    let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192)
    let signed = signPlaceholder(draft, leafSigner())
    writeFile("/tmp/p4b_ours.pdf", signed.file)
    let covered = coveredBytes(signed.file, signed.byteRange)
    writeFile("/tmp/p4b_covered.bin", covered)
    writeFile("/tmp/p4b_ours.der",
      cmsOf(signed.file, signed.contentsAt + 1, signed.contentsLen - 1))
    let (outp, code) = execCmdEx(exe & " cms -verify -in /tmp/p4b_ours.der" &
      " -inform DER -content /tmp/p4b_covered.bin -CAfile " & SignDir &
      "ca.cert.pem -purpose any -binary -out /dev/null")
    check code == 0

test "we verify openssl's cms":
  let exe = findExe("openssl")
  if exe.len == 0:
    skip()
  else:
    let draft = addSignaturePlaceholder(textBase(), "Sig1", 8192)
    let covered = coveredBytes(draft.file, draft.byteRange)
    writeFile("/tmp/p4b_covered.bin", covered)
    let (_, sc) = execCmdEx(exe & " cms -sign -signer " & SignDir &
      "leaf.cert.pem -inkey " & SignDir &
      "leaf.key -in /tmp/p4b_covered.bin -outform DER -binary -out /tmp/p4b_ossl.der")
    check sc == 0
    let filled = fillPlaceholder(draft, readFile("/tmp/p4b_ossl.der"))
    let r = verifySignature(filled.file, "Sig1",
      @[readFile(SignDir & "ca.cert.der")])
    check r.valid
    check r.digestOk and r.sigOk and r.chainOk