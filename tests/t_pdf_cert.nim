## P4 tests: X.509 parse, Name matching, chain building.
##
## Fixtures generated locally with OpenSSL 3.6.3 (no licensing
## concerns): a test CA (CA:true, keyCertSign), a leaf it signed
## (codeSigning EKU), and a self-signed P-256 EC leaf. Keys are
## test-only material under tests/data/pdf/sign/.

import std/times
import unittest
import ../src/opendocs/pdf
import ../src/opendocs/pdf/cert
import ../src/opendocs/pdf/der

const SignDir = "tests/data/pdf/sign/"

proc utcNow(): DateTime =
  now().utc

test "leaf parses with extensions":
  let c = parseCert(readFile(SignDir & "leaf.cert.der"))
  check certLabel(c) == "Test Signer"
  check c.sigAlgOid == derOidContent([1, 2, 840, 113549, 1, 1, 11])
  check c.basicCa == false
  check (c.keyUsage and 1) != 0
  check c.eku.len == 1
  check c.ski.len > 0
  check c.aki.len > 0
  check c.spki.isRsa
  check not c.spki.isEc
  check c.validity.notBefore < c.validity.notAfter

test "ca parses as ca":
  let c = parseCert(readFile(SignDir & "ca.cert.der"))
  check c.basicCa == true
  check (c.keyUsage and (1 shl 5)) != 0

test "ec leaf parses":
  let c = parseCert(readFile(SignDir & "ec.cert.der"))
  check c.spki.isEc
  check not c.spki.isRsa

test "names match across order and case":
  let ca = parseCert(readFile(SignDir & "ca.cert.der"))
  let leaf = parseCert(readFile(SignDir & "leaf.cert.der"))
  check namesMatch(leaf.issuer, ca.subject)
  check not namesMatch(leaf.subject, ca.subject)

test "chain validates to the ca":
  let ca = parseCert(readFile(SignDir & "ca.cert.der"))
  let leaf = parseCert(readFile(SignDir & "leaf.cert.der"))
  check checkChain(@[leaf], @[ca], utcNow()).len == 0

test "chain fails without the anchor":
  let leaf = parseCert(readFile(SignDir & "leaf.cert.der"))
  check checkChain(@[leaf], @[], utcNow()) ==
    @["chain does not lead to a trust anchor"]

test "chain fails on wrong anchor":
  let leaf = parseCert(readFile(SignDir & "leaf.cert.der"))
  let ec = parseCert(readFile(SignDir & "ec.cert.der"))
  let r = checkChain(@[leaf], @[ec], utcNow())
  check r.len == 1

test "tampered signature fails crypto":
  var raw = readFile(SignDir & "leaf.cert.der")
  # Flip a byte deep in the signatureValue (last 32 bytes are sig).
  raw[^1] = char(byte(raw[^1]) xor 0xFF)
  let bad = parseCert(raw)
  let ca = parseCert(readFile(SignDir & "ca.cert.der"))
  check checkChain(@[bad], @[ca], utcNow()) ==
    @["signature mismatch on 'Test Signer'"]

test "malformed der fails loudly":
  expect PdfError:
    discard parseCert("not a certificate")
  expect PdfError:
    discard parseCert("\x30\x03\x02\x01")
