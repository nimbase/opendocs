## X.509 certificates (M19 P4): parse, Name matching, chain building.
##
## Parses the fields PAdES needs: issuer/serial (SignerInfo),
## validity, subjectPublicKeyInfo (signature verify + key import),
## basicConstraints/keyUsage/authorityKeyId for chain building, and the
## raw tbsCertificate bytes (the signature input). Extensions beyond
## basicConstraints, keyUsage, subject/authorityKeyId and
## extendedKeyUsage are ignored (documented, not failed): unknown
## critical extensions fail loudly, since ignoring a constraint the
## issuer marked critical would be a silent security defect.
##
## Name comparison follows RFC 5280 section 6.1 in spirit: RDNs match
## as multisets (order irrelevant), values fold case and whitespace
## for DirectoryString types. It is an approximation, documented here:
## exotic string-type substitutions compare by folded text.
##
## SHA-1 verifies (crypto is crypto) with no warning here; weak-digest
## reporting lives in `verifySignature`, which owns user-facing trust.
## RSASSA-PSS, EdDSA and DSA fail loudly as unsupported.

import std/algorithm
import std/base64
import std/strutils
import std/times
import nimcypher/algos/rsa as rsaAlgo
import nimcypher/algos/ecdsa as ecdsaAlgo
import nimcypher/algos/bigint_ext
import ./types
import ./lexer
import ./der

type
  CertName* = seq[tuple[oid: string, value: string]] ## sorted ATV pairs

  Validity* = object
    notBefore*, notAfter*: DateTime

  Spki* = object
    algDer*: string ## full AlgorithmIdentifier DER
    keyDer*: string ## BIT STRING content bytes (without unused-bits octet)
    isRsa*: bool
    isEc*: bool
    curve*: string ## EC curve OID content bytes ("" when not EC)

  Cert* = object
    raw*: string ## full Certificate DER
    tbs*: string ## tbsCertificate DER (signature input)
    serial*: string ## INTEGER content bytes
    sigAlgDer*: string ## outer signatureAlgorithm DER
    sigAlgOid*: string ## its OID content bytes
    issuer*: CertName
    issuerDer*: string
    validity*: Validity
    subject*: CertName
    subjectDer*: string
    spki*: Spki
    basicCa*: bool
    pathLen*: int ## -1 when absent
    keyUsage*: int ## bitmask, -1 when absent
    ski*: string ## subject key id bytes ("" when absent)
    aki*: string ## authority key id bytes ("" when absent)
    eku*: seq[string] ## EKU OID contents (empty when absent)

proc oidContent(arcs: openArray[int]): string =
  derOid(arcs)[2 .. ^1]

const
  oidRsaEncryption = [1, 2, 840, 113549, 1, 1, 1]
  oidEcPublicKey = [1, 2, 840, 10045, 2, 1]
  oidCurveP256 = [1, 2, 840, 10045, 3, 1, 7]
  oidCurveP384 = [1, 3, 132, 0, 34]
  oidCurveP521 = [1, 3, 132, 0, 35]
  oidCurveSecp256k1 = [1, 3, 132, 0, 10]
  oidSha256Rsa = [1, 2, 840, 113549, 1, 1, 11]
  oidSha384Rsa = [1, 2, 840, 113549, 1, 1, 12]
  oidSha512Rsa = [1, 2, 840, 113549, 1, 1, 13]
  oidSha1Rsa = [1, 2, 840, 113549, 1, 1, 5]
  oidEcdsaSha256 = [1, 2, 840, 10045, 4, 3, 2]
  oidEcdsaSha384 = [1, 2, 840, 10045, 4, 3, 3]
  oidEcdsaSha512 = [1, 2, 840, 10045, 4, 3, 4]
  oidBasicConstraints = [2, 5, 29, 19]
  oidKeyUsage = [2, 5, 29, 15]
  oidSki = [2, 5, 29, 14]
  oidAki = [2, 5, 29, 35]
  oidEku = [2, 5, 29, 37]

proc pemToDer*(pem: string): string =
  ## DER bytes from a PEM block (headers stripped, base64 joined).
  ## Fails loudly outside a BEGIN/END pair or on bad base64.
  let b = pem.find("-----BEGIN ")
  let e = pem.find("-----END ")
  if b < 0 or e < 0 or e <= b:
    pdfFail("not a PEM block (missing BEGIN/END lines)")
  var body = ""
  let inner = pem[b ..< e]
  for line in inner.splitLines():
    let t = line.strip()
    if t.len == 0 or t.startsWith("-----"):
      continue
    body.add(t)
  try:
    decode(body)
  except ValueError as err:
    pdfFail("PEM base64 does not decode (" & err.msg & ")")

proc expectTag(n: DerNode, tag: byte, what: string) =
  if n.tag != tag:
    pdfFail(what & " is not the expected type")

proc expectSeq(n: DerNode, what: string): seq[DerNode] =
  if n.tag != 0x30:
    pdfFail(what & " is not a SEQUENCE")
  n.derChildren()

proc getSeq(data: string, what: string): seq[DerNode] =
  derParse(data).expectSeq(what)

proc bmpToUtf8(raw: string): string =
  if raw.len mod 2 != 0:
    pdfFail("BMPString has an odd length")
  var i = 0
  while i < raw.len:
    let cp = int(byte(raw[i])) * 256 + int(byte(raw[i + 1]))
    i += 2
    if cp < 0x80:
      result.add(char(cp))
    elif cp < 0x800:
      result.add(char(0xC0 or (cp shr 6)))
      result.add(char(0x80 or (cp and 0x3F)))
    elif cp >= 0xD800 and cp <= 0xDFFF:
      pdfFail("BMPString holds a surrogate")
    else:
      result.add(char(0xE0 or (cp shr 12)))
      result.add(char(0x80 or ((cp shr 6) and 0x3F)))
      result.add(char(0x80 or (cp and 0x3F)))

proc foldValue(s: string): string =
  ## RFC 5280 stringprep approximation: strip, collapse runs, fold case.
  var parts: seq[string] = @[]
  for w in s.splitWhitespace():
    parts.add(w)
  parts.join(" ").toLowerAscii()

proc atvText(tag: byte, raw: string): string =
  case tag
  of 0x13, 0x0C, 0x16, 0x14: # Printable/UTF8/IA5/Teletex (latin-1 range)
    result = raw
  of 0x1E:
    result = bmpToUtf8(raw)
  of 0x1C:
    if raw.len mod 4 != 0:
      pdfFail("UniversalString has a bad length")
    var i = 0
    while i < raw.len:
      let cp = int(byte(raw[i])) * 16777216 + int(byte(raw[i + 1])) *
        65536 + int(byte(raw[i + 2])) * 256 + int(byte(raw[i + 3]))
      i += 4
      if cp < 0x80:
        result.add(char(cp))
      elif cp < 0x800:
        result.add(char(0xC0 or (cp shr 6)))
        result.add(char(0x80 or (cp and 0x3F)))
      elif cp > 0xFFFF:
        pdfFail("UniversalString outside the BMP is not supported")
      else:
        result.add(char(0xE0 or (cp shr 12)))
        result.add(char(0x80 or ((cp shr 6) and 0x3F)))
        result.add(char(0x80 or (cp and 0x3F)))
  else:
    pdfFail("unsupported DirectoryString tag")

proc parseName(node: DerNode, what: string): CertName =
  ## RDNSequence as (oid content, raw text) pairs in document order.
  ## Case/space folding happens in namesMatch, so parsing preserves
  ## the on-wire values for messages.
  let rdns = node.expectSeq(what & " Name")
  for rdn in rdns:
    if rdn.tag != 0x31:
      pdfFail(what & " RDN is not a SET")
    for atv in rdn.derChildren():
      let parts = atv.expectSeq(what & " attribute")
      if parts.len != 2:
        pdfFail(what & " attribute is not an OID/value pair")
      if parts[0].tag != 0x06:
        pdfFail(what & " attribute type is not an OID")
      result.add((parts[0].content,
        atvText(parts[1].tag, parts[1].content)))

proc namesMatch*(a, b: CertName): bool =
  ## Multiset compare with DirectoryString folding (order, case and
  ## whitespace insensitive per RFC 5280 6.1).
  if a.len != b.len:
    return false
  var fa: seq[tuple[oid, value: string]] = @[]
  var fb: seq[tuple[oid, value: string]] = @[]
  for (oid, value) in a:
    fa.add((oid, foldValue(value)))
  for (oid, value) in b:
    fb.add((oid, foldValue(value)))
  fa.sort()
  fb.sort()
  fa == fb

proc twoDigits(s: string, pos: int): int =
  if pos + 1 >= s.len or s[pos] notin {'0'..'9'} or
      s[pos + 1] notin {'0'..'9'}:
    pdfFail("bad digit in certificate time")
  (ord(s[pos]) - ord('0')) * 10 + (ord(s[pos + 1]) - ord('0'))

proc parseDerTime*(tag: byte, raw: string): DateTime =
  ## UTCTime and GeneralizedTime with an optional numeric zone.
  ## Two-digit years map per RFC 5280 (00-49 to 20xx, else 19xx).
  var s = raw
  var isUtc = false
  case tag
  of 0x17:
    isUtc = true
    if s.len != 13 and s.len != 15 and s.len != 17:
      pdfFail("UTCTime has a bad length")
  of 0x18:
    if s.len != 15 and s.len != 17 and s.len != 19:
      pdfFail("GeneralizedTime has a bad length")
  else:
    pdfFail("certificate time is not UTCTime/GeneralizedTime")
  var year, mon, day, hour, minu, sec: int
  var pos = 0
  if isUtc:
    let yy = twoDigits(s, 0)
    year = if yy < 50: 2000 + yy else: 1900 + yy
    pos = 2
  else:
    for c in s[0 ..< 4]:
      if c notin {'0'..'9'}:
        pdfFail("bad year in certificate time")
    try:
      year = parseInt(s[0 ..< 4])
    except ValueError:
      pdfFail("bad year in certificate time")
    pos = 4
  mon = twoDigits(s, pos); day = twoDigits(s, pos + 2)
  hour = twoDigits(s, pos + 4); minu = twoDigits(s, pos + 6)
  sec = twoDigits(s, pos + 8)
  pos += 10
  var tzMin = 0
  if pos < s.len:
    if s[pos] == 'Z':
      pos += 1
    elif s[pos] == '+' or s[pos] == '-':
      let sign = if s[pos] == '+': 1 else: -1
      let oh = twoDigits(s, pos + 1)
      let om =
        if pos + 3 < s.len and s[pos + 3] != '\'':
          twoDigits(s, pos + 3)
        else:
          0
      tzMin = sign * (oh * 60 + om)
      while pos < s.len and s[pos] notin {'0'..'9'} and s[pos] != 'Z':
        inc pos
      while pos < s.len and s[pos] in {'0'..'9'}:
        inc pos
      if pos < s.len and s[pos] == '\'':
        inc pos
        while pos < s.len and s[pos] in {'0'..'9'}:
          inc pos
        if pos < s.len and s[pos] == '\'':
          inc pos
    else:
      pdfFail("bad zone in certificate time")
  if pos != s.len:
    pdfFail("trailing bytes in certificate time")
  try:
    result = dateTime(year, Month(mon), MonthdayRange(day), HourRange(hour),
      MinuteRange(minu), SecondRange(sec), 0, utc()) - initDuration(
        minutes = tzMin)
  except RangeDefect, ValueError:
    pdfFail("certificate time out of range")

proc splitTop(content: string,
    base: int): seq[tuple[n: DerNode, off, len: int]] =
  ## Children of a constructed value with absolute input offsets.
  var pos = 0
  while pos < content.len:
    let s = pos
    let n = derRead(content, pos)
    result.add((n, base + s, pos - s))
  if pos != content.len:
    pdfFail("DER children overran their parent")

proc sliceAt(der: string, off, len: int): string =
  if off < 0 or len < 0 or off + len > der.len:
    pdfFail("internal error slicing certificate DER")
  der[off ..< off + len]

proc parseCert*(der: string): Cert =
  ## Full parse; every structural surprise fails loudly.
  result.raw = der
  result.pathLen = -1
  result.keyUsage = -1
  let outer = derParse(der)
  if outer.tag != 0x30:
    pdfFail("Certificate is not a SEQUENCE")
  let outerHeader = outer.total - outer.content.len
  let oKids = splitTop(outer.content, outerHeader)
  if oKids.len != 3:
    pdfFail("Certificate is not 3 parts")
  let tbsNode = oKids[0].n
  if tbsNode.tag != 0x30:
    pdfFail("tbsCertificate is not a SEQUENCE")
  result.tbs = sliceAt(der, oKids[0].off, oKids[0].len)
  let tbsHeader = tbsNode.total - tbsNode.content.len
  let tKids = splitTop(tbsNode.content, oKids[0].off + tbsHeader)
  var i = 0
  if tKids[i].n.tag == 0xA0:
    let inner = tKids[i].n.derChildren()
    if inner.len != 1 or inner[0].tag != 0x02:
      pdfFail("tbsCertificate version is not [0] INTEGER")
    inc i
  if i >= tKids.len or tKids[i].n.tag != 0x02:
    pdfFail("tbsCertificate serialNumber is not an INTEGER")
  result.serial = tKids[i].n.content
  let sigIdx = i + 1
  if sigIdx >= tKids.len or tKids[sigIdx].n.tag != 0x30:
    pdfFail("tbsCertificate signature is not an AlgorithmIdentifier")
  let sigAlgKids = tKids[sigIdx].n.derChildren()
  if sigAlgKids.len == 0 or sigAlgKids[0].tag != 0x06:
    pdfFail("signature AlgorithmIdentifier has no OID")
  result.sigAlgDer = sliceAt(der, tKids[sigIdx].off, tKids[sigIdx].len)
  let issuerIdx = sigIdx + 1
  if issuerIdx >= tKids.len:
    pdfFail("tbsCertificate ends before issuer")
  result.issuer = parseName(tKids[issuerIdx].n, "issuer")
  result.issuerDer = sliceAt(der, tKids[issuerIdx].off,
    tKids[issuerIdx].len)
  let valIdx = issuerIdx + 1
  if valIdx >= tKids.len:
    pdfFail("tbsCertificate ends before validity")
  let valKids = tKids[valIdx].n.expectSeq("validity")
  if valKids.len != 2:
    pdfFail("validity is not two times")
  result.validity = Validity(
    notBefore: parseDerTime(valKids[0].tag, valKids[0].content),
    notAfter: parseDerTime(valKids[1].tag, valKids[1].content))
  let subIdx = valIdx + 1
  if subIdx >= tKids.len:
    pdfFail("tbsCertificate ends before subject")
  result.subject = parseName(tKids[subIdx].n, "subject")
  result.subjectDer = sliceAt(der, tKids[subIdx].off,
    tKids[subIdx].len)
  let spkiIdx = subIdx + 1
  if spkiIdx >= tKids.len or tKids[spkiIdx].n.tag != 0x30:
    pdfFail("tbsCertificate subjectPublicKeyInfo is not a SEQUENCE")
  let spkiNode = tKids[spkiIdx].n
  let spkiKids = spkiNode.derChildren()
  if spkiKids.len != 2 or spkiKids[0].tag != 0x30 or
      spkiKids[1].tag != 0x03:
    pdfFail("subjectPublicKeyInfo is not alg + BIT STRING")
  let spkiHeader = spkiNode.total - spkiNode.content.len
  let spkiParts = splitTop(spkiNode.content,
    tKids[spkiIdx].off + spkiHeader)
  if spkiParts.len != 2:
    pdfFail("subjectPublicKeyInfo is not alg + BIT STRING")
  result.spki.algDer = sliceAt(der, spkiParts[0].off, spkiParts[0].len)
  let algKids = spkiKids[0].derChildren()
  if algKids.len == 0 or algKids[0].tag != 0x06:
    pdfFail("subjectPublicKeyInfo algorithm has no OID")
  let bitStr = spkiKids[1].content
  if bitStr.len == 0 or byte(bitStr[0]) != 0:
    pdfFail("subjectPublicKeyInfo has unused key bits")
  result.spki.keyDer = bitStr[1 .. ^1]
  let keyOid = algKids[0].content
  if keyOid == oidContent(oidRsaEncryption):
    result.spki.isRsa = true
  elif keyOid == oidContent(oidEcPublicKey):
    result.spki.isEc = true
    if algKids.len < 2 or algKids[1].tag != 0x06:
      pdfFail("EC subjectPublicKeyInfo lacks a curve OID")
    result.spki.curve = algKids[1].content
  else:
    pdfFail("subjectPublicKeyInfo algorithm is not RSA or EC")
  # Optional issuer/subject unique IDs ([1]/[2]) then extensions ([3]).
  var extNode = DerNode()
  var hasExt = false
  var j = spkiIdx + 1
  while j < tKids.len:
    if tKids[j].n.tag == 0xA1 or tKids[j].n.tag == 0xA2:
      inc j
      continue
    elif tKids[j].n.tag == 0xA3:
      let inner = tKids[j].n.derChildren()
      if inner.len != 1 or inner[0].tag != 0x30:
        pdfFail("extensions [3] does not wrap a SEQUENCE")
      extNode = inner[0]
      hasExt = true
      inc j
    else:
      pdfFail("unexpected tbsCertificate field")
  result.basicCa = false
  if hasExt:
    for ext in extNode.derChildren():
      let ek = ext.expectSeq("extension")
      if ek.len < 2 or ek.len > 3 or ek[0].tag != 0x06:
        pdfFail("extension is not OID + optional critical + value")
      var crit = false
      var valNode = ek[1]
      if ek.len == 3:
        if ek[1].tag != 0x01:
          pdfFail("extension critical is not BOOLEAN")
        crit = ek[1].content == "\xFF"
        valNode = ek[2]
      if valNode.tag != 0x04:
        pdfFail("extension value is not an OCTET STRING")
      let oid = ek[0].content
      if oid == oidContent(oidBasicConstraints):
        let bk = getSeq(valNode.content, "basicConstraints")
        for b in bk:
          if b.tag == 0x01:
            result.basicCa = b.content == "\xFF"
          elif b.tag == 0x02:
            if b.content.len == 0 or b.content.len > 4:
              pdfFail("basicConstraints pathLen is not an INTEGER")
            if byte(b.content[0]) >= 0x80:
              pdfFail("negative pathLen is not supported")
            var v = 0
            for c in b.content:
              v = v * 256 + int(byte(c))
            result.pathLen = v
          else:
            pdfFail("basicConstraints holds an unknown field")
      elif oid == oidContent(oidKeyUsage):
        let uk = derParse(valNode.content)
        if uk.tag != 0x03 or uk.content.len == 0:
          pdfFail("keyUsage is not a BIT STRING")
        let unused = int(byte(uk.content[0]))
        if unused < 0 or unused > 7:
          pdfFail("keyUsage has bad unused-bits")
        let total = (uk.content.len - 1) * 8
        if unused > total:
          pdfFail("keyUsage unused-bits exceed the bits")
        var mask = 0
        for k in 0 ..< total - unused:
          let byteIdx = 1 + k div 8
          let bitIdx = k mod 8
          if (byte(uk.content[byteIdx]) and
              byte(0x80 shr bitIdx)) != 0:
            mask = mask or (1 shl k)
        result.keyUsage = mask
      elif oid == oidContent(oidSki):
        let sk = derParse(valNode.content)
        if sk.tag != 0x04:
          pdfFail("subjectKeyIdentifier is not an OCTET STRING")
        result.ski = sk.content
      elif oid == oidContent(oidAki):
        for ak in getSeq(valNode.content, "authorityKeyIdentifier"):
          if ak.tag == 0x80 and result.aki.len == 0:
            result.aki = ak.content
      elif oid == oidContent(oidEku):
        for ekv in getSeq(valNode.content, "extKeyUsage"):
          if ekv.tag != 0x06:
            pdfFail("extKeyUsage holds a non-OID")
          result.eku.add(ekv.content)
      else:
        # Unknown non-critical extensions are ignored; critical ones
        # fail because ignoring a constraint would be unsound.
        if crit:
          pdfFail("unsupported critical extension present")
  # Outer signature algorithm must match the tbs one.
  if oKids[1].n.tag != 0x30:
    pdfFail("outer signatureAlgorithm is not a SEQUENCE")
  let outerKids = oKids[1].n.derChildren()
  if outerKids.len == 0 or outerKids[0].tag != 0x06:
    pdfFail("outer signatureAlgorithm has no OID")
  result.sigAlgOid = outerKids[0].content
  if result.sigAlgOid != sigAlgKids[0].content:
    pdfFail("outer and tbs signature algorithms differ")
  if oKids[2].n.tag != 0x03:
    pdfFail("Certificate signatureValue is not a BIT STRING")

# ---------------------------------------------------------------------------
# Key import + signature verification
# ---------------------------------------------------------------------------

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc intMagnitude(raw: string): string =
  ## DER INTEGER content to unsigned magnitude bytes: drops the sign
  ## pad (one leading zero ahead of a high-bit byte) and redundant
  ## zeros. Fails on empty and negative inputs.
  if raw.len == 0:
    pdfFail("empty INTEGER where a value was expected")
  if byte(raw[0]) >= 0x80:
    pdfFail("negative INTEGER where a magnitude was expected")
  var i = 0
  if raw.len > 1 and raw[0] == '\0' and
      (byte(raw[1]) and 0x80) != 0:
    i = 1
  while i + 1 < raw.len and raw[i] == '\0' and
      (byte(raw[i + 1]) and 0x80) == 0:
    inc i
  raw[i .. ^1]

proc bytesToInt(raw: string): auto =
  ## Big-endian DER INTEGER content to BigInt (magnitude).
  fromBytesBE(toBytes(intMagnitude(raw)))

proc rsaPublicKeyFromSpki*(spki: Spki): rsaAlgo.RsaPublicKey =
  ## RSAPublicKey inside the BIT STRING. Fails on EC keys.
  if not spki.isRsa:
    pdfFail("SPKI is not an RSA key")
  let kids = getSeq(spki.keyDer, "RSAPublicKey")
  if kids.len != 2 or kids[0].tag != 0x02 or kids[1].tag != 0x02:
    pdfFail("RSAPublicKey is not two INTEGERs")
  let n = bytesToInt(kids[0].content)
  let e = bytesToInt(kids[1].content)
  rsaAlgo.RsaPublicKey(n: n, e: e,
    k: intMagnitude(kids[0].content).len)

proc ecCurveOf(curveOid: string): ecdsaAlgo.EcCurve =
  if curveOid == oidContent(oidCurveP256):
    ecdsaAlgo.P256
  elif curveOid == oidContent(oidCurveP384):
    ecdsaAlgo.P384
  elif curveOid == oidContent(oidCurveP521):
    ecdsaAlgo.P521
  elif curveOid == oidContent(oidCurveSecp256k1):
    ecdsaAlgo.Secp256k1
  else:
    pdfFail("unsupported EC curve")

proc ecPublicKeyFromSpki*(spki: Spki): ecdsaAlgo.EcPublicKey =
  ## Uncompressed-point BIT STRING to a public key. Compressed points
  ## fail loudly (no point decompression in this module).
  if not spki.isEc:
    pdfFail("SPKI is not an EC key")
  let curve = ecCurveOf(spki.curve)
  let cp = ecdsaAlgo.curveParams(curve)
  let raw = spki.keyDer
  if raw.len != 1 + 2 * cp.coordLen or byte(raw[0]) != 4:
    pdfFail("EC point is not uncompressed")
  let x = fromBytesBE(toBytes(raw[1 ..< 1 + cp.coordLen]))
  let y = fromBytesBE(
    toBytes(raw[1 + cp.coordLen ..< 1 + 2 * cp.coordLen]))
  ecdsaAlgo.EcPublicKey(curve: curve, x: x, y: y)

proc isRsaSigOid(oid: string): bool =
  oid == oidContent(oidSha256Rsa) or oid == oidContent(oidSha384Rsa) or
    oid == oidContent(oidSha512Rsa) or oid == oidContent(oidSha1Rsa)

proc isEcSigOid(oid: string): bool =
  oid == oidContent(oidEcdsaSha256) or
    oid == oidContent(oidEcdsaSha384) or
    oid == oidContent(oidEcdsaSha512)

proc rsaHashOf(sigOid: string): tuple[h: rsaAlgo.RsaHash, weak: bool] =
  if sigOid == oidContent(oidSha256Rsa):
    (rsaAlgo.rhSha256, false)
  elif sigOid == oidContent(oidSha384Rsa):
    (rsaAlgo.rhSha384, false)
  elif sigOid == oidContent(oidSha512Rsa):
    (rsaAlgo.rhSha512, false)
  elif sigOid == oidContent(oidSha1Rsa):
    (rsaAlgo.rhSha1, true)
  else:
    pdfFail("unsupported RSA signature algorithm")

proc derSigToRaw(sigDer: string, coordLen: int): seq[byte] =
  ## ECDSA CMS signatures are DER SEQ{INTEGER r, INTEGER s}; nimcypher
  ## verifies raw R||S. Minimal-encoding violations fail loudly.
  let kids = getSeq(sigDer, "ECDSA signature")
  if kids.len != 2 or kids[0].tag != 0x02 or kids[1].tag != 0x02:
    pdfFail("ECDSA signature is not two INTEGERs")
  for k in kids:
    if k.content.len == 0:
      pdfFail("ECDSA signature INTEGER is empty")
    if k.content.len > 1 and k.content[0] == '\0' and
        byte(k.content[1]) < 0x80:
      pdfFail("ECDSA signature INTEGER is not minimal")
    if byte(k.content[0]) >= 0x80:
      pdfFail("ECDSA signature INTEGER is negative")
  result = newSeq[byte](2 * coordLen)
  for si, k in kids:
    var mag = k.content
    while mag.len > 1 and mag[0] == '\0':
      mag = mag[1 .. ^1]
    if mag.len > coordLen:
      pdfFail("ECDSA signature component too long")
    let off = si * coordLen + (coordLen - mag.len)
    for i in 0 ..< mag.len:
      result[off + i] = byte(mag[i])

proc certLabel*(c: Cert): string =
  ## First CN value for messages, else first OU/O, else "(unnamed)".
  for (oid, value) in c.subject:
    if oid == oidContent([2, 5, 4, 3]):
      return value
  for (oid, value) in c.subject:
    if oid == oidContent([2, 5, 4, 11]) or
        oid == oidContent([2, 5, 4, 10]):
      return value
  "(unnamed)"

proc ecCurveFor(oid: string): ecdsaAlgo.EcCurve =
  ## Required key curve per ECDSA hash (hashMsg is curve-determined;
  ## secp256k1 hashes with SHA-256, hence allowed under SHA-256).
  if oid == oidContent(oidEcdsaSha256):
    ecdsaAlgo.P256
  elif oid == oidContent(oidEcdsaSha384):
    ecdsaAlgo.P384
  elif oid == oidContent(oidEcdsaSha512):
    ecdsaAlgo.P521
  else:
    pdfFail("unsupported ECDSA signature algorithm")

proc verifyCertSignature*(tbs, sigValue, sigAlgDer: string,
    issuerSpki: Spki): tuple[ok: bool, weak: bool] =
  ## `sigValue` is the BIT STRING content (without unused-bits octet).
  ## Returns ok=false on cryptographic mismatch (never raises for bad
  ## math); structural problems and unknown algorithms raise PdfError.
  ## `weak` is true for SHA-1 (still verified).
  let algKids = getSeq(sigAlgDer, "signatureAlgorithm")
  if algKids.len == 0 or algKids[0].tag != 0x06:
    pdfFail("signatureAlgorithm has no OID")
  let oid = algKids[0].content
  if algKids.len > 1:
    let p = algKids[1]
    if p.tag != 0x05 or p.content.len != 0:
      # RSA params must be NULL; ECDSA params must be absent.
      if isRsaSigOid(oid):
        pdfFail("RSA signature parameters are not NULL")
      elif isEcSigOid(oid):
        pdfFail("ECDSA signature has parameters")
      else:
        pdfFail("unsupported signature algorithm")
  elif not isRsaSigOid(oid) and not isEcSigOid(oid):
    pdfFail("unsupported signature algorithm")
  if isEcSigOid(oid):
    if not issuerSpki.isEc:
      pdfFail("ECDSA signature with a non-EC issuer key")
    let keyCurve = ecCurveOf(issuerSpki.curve)
    let wantCurve = ecCurveFor(oid)
    if keyCurve != wantCurve and
        not (oid == oidContent(oidEcdsaSha256) and
        keyCurve == ecdsaAlgo.Secp256k1):
      pdfFail("ECDSA signature hash does not match the key curve")
    let pub = ecPublicKeyFromSpki(issuerSpki)
    if not ecdsaAlgo.validatePublicKey(pub):
      pdfFail("issuer EC key fails validation")
    let coordLen = ecdsaAlgo.curveParams(keyCurve).coordLen
    (ecdsaAlgo.verify(pub, toBytes(tbs),
      derSigToRaw(sigValue, coordLen)), false)
  else:
    if not issuerSpki.isRsa:
      pdfFail("RSA signature with a non-RSA issuer key")
    let (h, weak) = rsaHashOf(oid)
    let pub = rsaPublicKeyFromSpki(issuerSpki)
    (rsaAlgo.pkcs1v15Verify(pub, h, toBytes(tbs), toBytes(sigValue)),
      weak)

proc checkChain*(chain: seq[Cert], trust: seq[Cert],
    at: DateTime): seq[string] =
  ## Empty means valid; else human-readable reasons. Walks leaf to
  ## anchor: Name match (multiset), validity window, CA/keyUsage
  ## constraints with pathLen, per-link signature verify. EKU without
  ## codeSigning on the leaf is a reason; weak digests are NOT reasons
  ## here (see verifySignature warnings).
  if chain.len == 0:
    pdfFail("certificate chain is empty")
  var path = chain
  # Find the anchor: first chain cert whose issuer matches a trust
  # subject (or a self-signed chain member already trusted).
  var anchorIdx = -1
  var anchor: Cert
  for i, c in path:
    for t in trust:
      if namesMatch(c.issuer, t.subject):
        anchorIdx = i
        anchor = t
        break
    if anchorIdx >= 0:
      break
  if anchorIdx < 0:
    # Maybe the leaf (or an intermediate) is itself trusted.
    for i, c in path:
      for t in trust:
        if namesMatch(c.subject, t.subject):
          anchorIdx = i
          anchor = t
          break
      if anchorIdx >= 0:
        break
  if anchorIdx < 0:
    return @["chain does not lead to a trust anchor"]
  # Validity of every cert up to and including the anchor target.
  for i in 0 .. anchorIdx:
    if at < path[i].validity.notBefore or
        at > path[i].validity.notAfter:
      return @["certificate '" & certLabel(path[i]) &
        "' is not valid at the signing time"]
  # Link signatures and CA constraints.
  var caCount = 0
  for i in 0 .. anchorIdx:
    let issuerCert =
      if i == anchorIdx: anchor
      else: path[i + 1]
    if not namesMatch(path[i].issuer, issuerCert.subject):
      return @["issuer mismatch on '" & certLabel(path[i]) & "'"]
    let sigBytes = block:
      let kids = derParse(path[i].raw).derChildren()
      let sv = kids[2]
      if sv.tag != 0x03 or sv.content.len < 1 or
          byte(sv.content[0]) != 0:
        return @["certificate '" & certLabel(path[i]) &
          "' has a bad signatureValue"]
      sv.content[1 .. ^1]
    let (ok, _) = verifyCertSignature(path[i].tbs, sigBytes,
      path[i].sigAlgDer, issuerCert.spki)
    if not ok:
      return @["signature mismatch on '" & certLabel(path[i]) & "'"]
  # Every chain cert above the leaf that is not itself the trusted
  # anchor copy must be a CA with keyCertSign and pathLen room.
  for i in 1 .. anchorIdx:
    let ca = path[i]
    if ca.raw == anchor.raw:
      continue # the anchor copy: trusted by inclusion, not by flag
    if not ca.basicCa:
      return @["issuer '" & certLabel(ca) & "' is not a CA"]
    if ca.keyUsage >= 0 and (ca.keyUsage and (1 shl 5)) == 0:
      return @["issuer '" & certLabel(ca) & "' lacks keyCertSign"]
    if ca.pathLen >= 0 and (i - 1) > ca.pathLen:
      return @["pathLen violated at '" & certLabel(ca) & "'"]
  # Leaf key usage and extended key usage.
  let leaf = path[0]
  if leaf.keyUsage >= 0 and
      (leaf.keyUsage and ((1 shl 0) or (1 shl 1))) == 0:
    return @["leaf lacks digitalSignature use"]
  if leaf.eku.len > 0:
    var ok = false
    for e in leaf.eku:
      if e == oidContent([1, 3, 6, 1, 5, 5, 7, 3, 3]):
        ok = true
    if not ok:
      return @["leaf lacks the codeSigning EKU"]
  @[]
