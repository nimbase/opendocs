## Document signatures, PAdES baseline (M12, P4a).
##
## `docSignatures` lists every /Sig field's value dictionary: filter,
## sub-filter, /ByteRange, /Contents, and the /M entries (reason,
## location, contact, date). `verifyByteRangeHash` returns the hex
## SHA-256 digest of the bytes covered by /ByteRange — the exact input
## an external CMS signer hashes and the value a P4b verifier compares
## against the embedded CMS messageDigest. `addSignaturePlaceholder`
## appends an unsigned shell (zeroed /Contents, patched /ByteRange)
## ready for out-of-band signing.
##
## Out of scope for P4a: CMS/PKCS#7 build and verification (B-B),
## timestamps, DSS/VRI (B-T/LT/LTA). Those need a CMS dependency and
## land in P4b; until then signature *creation* is external.

import std/strutils
import std/times
import nimcypher/algos/sha256
import nimcypher/algos/sha384 as sha384Algo
import nimcypher/algos/sha512 as sha512Algo
import nimcypher/rsa as nimRsa
import nimcypher/ecdsa as nimEcdsa
import nimcypher/algos/bigint_ext
import ./types
import ./cos
import ./docmodel
import ./write
import ./forms
import ./der
import ./cert
import ./catalog

type
  DocSignature* = object
    field*: string ## dotted field name holding the /V Sig dict
    filter*: string ## /Filter name ("" when absent)
    subFilter*: string ## /SubFilter name ("" when absent)
    byteRange*: array[4, int] ## /ByteRange offsets/lengths
    hasByteRange*: bool
    contents*: string ## raw /Contents bytes (zeroed when unsigned)
    signed*: bool ## contents present and not all zeros
    reason*: string
    location*: string
    contact*: string
    signDate*: string ## /M date string ("" when absent)

  SigDraft* = object
    file*: string ## file bytes with valid /ByteRange, zeroed /Contents
    field*: string
    byteRange*: array[4, int]
    contentsAt*: int ## offset of '<' opening /Contents in file
    contentsLen*: int ## span from '<' through '>' inclusive
    baseLen*: int ## length of the pre-update base (rebuild anchor)

proc strEntry(d: CosObj, key: string): string =
  let v = d.dictGet(key)
  if v.kind == coStr: v.sval else: ""

proc nameEntry(d: CosObj, key: string): string =
  let v = d.dictGet(key)
  if v.kind == coName: v.name else: ""

proc docSignatures*(d: var PdfDoc): seq[DocSignature] =
  ## Every signature field value in document order. Missing /V means
  ## an unsigned, unprepared field (empty contents, no byte range).
  result = @[]
  for f in d.rawFields():
    if kindOf(f.inh) != fkSignature:
      continue
    var sig = DocSignature(field: f.fullName)
    let v = d.resolve(f.inh.v)
    if v.kind != coDict:
      result.add(sig)
      continue
    sig.filter = nameEntry(v, "Filter")
    sig.subFilter = nameEntry(v, "SubFilter")
    sig.reason = strEntry(v, "Reason")
    sig.location = strEntry(v, "Location")
    sig.contact = strEntry(v, "ContactInfo")
    sig.signDate = strEntry(v, "M")
    let c = v.dictGet("Contents")
    if c.kind == coStr:
      sig.contents = c.sval
      for ch in c.sval:
        if ch != '\0':
          sig.signed = true
          break
    let br = v.dictGet("ByteRange")
    if br.kind == coArray and br.items.len == 4:
      var ok = true
      for i in 0 .. 3:
        if br.items[i].kind != coInt or br.items[i].ival < 0:
          ok = false
        else:
          sig.byteRange[i] = br.items[i].ival
      sig.hasByteRange = ok
    result.add(sig)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc sha256Hex(s: string): string =
  result = ""
  for b in sha256(toBytes(s)):
    result.add(toHex(int(b), 2))

proc verifyByteRangeHash*(data: string, sig: DocSignature): string =
  ## Hex SHA-256 over data[r0 ..< r0+r1] + data[r2 ..< r2+r3].
  ## Raises PdfError on missing or out-of-bounds ranges. The digest
  ## covers everything except the /Contents hex string itself, so any
  ## post-signing edit flips it.
  if not sig.hasByteRange:
    pdfFail("signature '" & sig.field & "' has no /ByteRange")
  let (o1, l1, o2, l2) = (sig.byteRange[0], sig.byteRange[1],
    sig.byteRange[2], sig.byteRange[3])
  if l1 < 0 or l2 < 0 or o1 < 0 or o2 < 0 or o1 + l1 > o2 or
      o2 + l2 > data.len:
    pdfFail("signature '" & sig.field &
      "' /ByteRange out of bounds for " & $data.len & " bytes")
  sha256Hex(data[o1 ..< o1 + l1] & data[o2 ..< o2 + l2])

const byteRangeSlot = "0000000000"

proc pdfDate(): string =
  ## Current UTC time as a PDF date string.
  let t = now().utc
  "(D:" & t.format("yyyyMMddHHmmss") & "+00'00')"

proc addSignaturePlaceholder*(base: string, fieldName = "Signature1",
    size = 8192, reason = "", location = "", contact = "",
    subFilter = "adbe.pkcs7.detached"): SigDraft =
  ## Append an unsigned signature shell: /Sig dict with zeroed
  ## /Contents (`size` bytes as hex) and a /ByteRange patched to the
  ## final offsets, plus an /FT /Sig field (no widget: invisible
  ## signature). Joins the existing /AcroForm or creates one.
  ## Returns the file plus the content span for the signer.
  ## `reason`/`location`/`contact` land as /Reason /Location
  ## /ContactInfo now: in-place signing cannot grow the dict later.
  ## `subFilter` selects adbe.pkcs7.detached (PKCS#7/CMS) or
  ## ETSI.CAdES.detached (CAdES); anything else fails loudly.
  if fieldName.len == 0:
    pdfFail("signature field name must not be empty")
  if size <= 0 or size > 1_000_000:
    pdfFail("signature placeholder size out of range (1..1000000)")
  if subFilter != "adbe.pkcs7.detached" and
      subFilter != "ETSI.CAdES.detached":
    pdfFail("unknown signature SubFilter '" & subFilter & "'")
  var donor = openDoc(base)
  if donor.crypt.present:
    pdfFail("signature placeholder supports unencrypted documents " &
      "only (file has /Encrypt)")
  for f in donor.rawFields():
    if f.fullName == fieldName:
      pdfFail("form field '" & fieldName & "' already exists")
  var hex = newStringOfCap(size * 2)
  for _ in 0 ..< size * 2:
    hex.add('0')
  let brHolder = "/ByteRange [" & byteRangeSlot & " " & byteRangeSlot &
    " " & byteRangeSlot & " " & byteRangeSlot & "]"
  var extra = ""
  if reason.len > 0:
    extra.add(" /Reason " & writeStr(reason))
  if location.len > 0:
    extra.add(" /Location " & writeStr(location))
  if contact.len > 0:
    extra.add(" /ContactInfo " & writeStr(contact))
  let sigBody = "<< /Type /Sig /Filter /Adobe.PPKLite " &
    "/SubFilter /" & subFilter & " " & brHolder & " /Contents <" &
    hex & "> /M " & pdfDate() & extra & " >>"
  var u = beginUpdate(base)
  let sigNum = u.addObject(sigBody)
  let fieldBody = writeCos(CosObj(kind: coDict,
    keys: @["FT", "T", "V"],
    vals: @[CosObj(kind: coName, name: "Sig"),
      CosObj(kind: coStr, sval: fieldName),
      CosObj(kind: coRef, refNum: sigNum, refGen: 0)]))
  let fieldNum = u.addObject(fieldBody)
  let fieldRef = CosObj(kind: coRef, refNum: fieldNum, refGen: 0)
  let cat = donor.catalog()
  let acroRef = cat.dictGet("AcroForm")
  if acroRef.kind == coNull:
    let acroNum = u.addObject(writeCos(CosObj(kind: coDict,
      keys: @["Fields"],
      vals: @[CosObj(kind: coArray, items: @[fieldRef])])))
    var ckeys = cat.keys
    var cvals = cat.vals
    ckeys.add("AcroForm")
    cvals.add(CosObj(kind: coRef, refNum: acroNum, refGen: 0))
    discard u.updateObject(u.rootNum,
      writeCos(CosObj(kind: coDict, keys: ckeys, vals: cvals)))
  elif acroRef.kind == coRef:
    let acro = donor.resolve(acroRef)
    if acro.kind != coDict:
      pdfFail("catalog /AcroForm is not a dictionary")
    var akeys = acro.keys
    var avals = acro.vals
    var found = false
    for i, k in akeys:
      if k == "Fields":
        if avals[i].kind != coArray:
          pdfFail("/AcroForm /Fields is not an array")
        avals[i].items.add(fieldRef)
        found = true
    if not found:
      akeys.add("Fields")
      avals.add(CosObj(kind: coArray, items: @[fieldRef]))
    discard u.updateObject(acroRef.refNum,
      writeCos(CosObj(kind: coDict, keys: akeys, vals: avals)))
  else:
    pdfFail("catalog /AcroForm must be an indirect reference")
  var file = u.finishUpdate()
  # Patch the fixed-width ByteRange slots in place: the four runs of
  # zeros keep their width, so offsets stay valid. rfind is strictly
  # correct for multi-signature documents (the new shell is last).
  let holder = "/ByteRange [" & byteRangeSlot & " " & byteRangeSlot &
    " " & byteRangeSlot & " " & byteRangeSlot & "]"
  let brPos = file.rfind(holder)
  if brPos < 0:
    pdfFail("internal error: ByteRange placeholder lost on write")
  let ltPos = file.find('<', brPos + holder.len)
  if ltPos < 0:
    pdfFail("internal error: Contents hex lost on write")
  let gtPos = file.find('>', ltPos + 1)
  if gtPos < 0:
    pdfFail("internal error: unterminated Contents hex")
  let nums = [0, ltPos, gtPos + 1, file.len - gtPos - 1]
  for v in nums:
    if v > 9_999_999_999:
      pdfFail("file too large for fixed-width /ByteRange patching")
  var patched = brPos + "/ByteRange [".len
  for v in nums:
    let s = align($v, 10, '0')
    for i in 0 ..< 10:
      file[patched + i] = s[i]
    patched += 11 # digits plus the following space or ]
  SigDraft(file: file, field: fieldName,
    byteRange: [nums[0], nums[1], nums[2], nums[3]],
    contentsAt: ltPos, contentsLen: gtPos + 1 - ltPos,
    baseLen: base.len)

# ---------------------------------------------------------------------------
# PAdES P4b: CMS build, signing, verification
# ---------------------------------------------------------------------------
#
# DER writing lives in der.nim, certificate parsing in cert.nim. This
# section loads signer keys, builds detached PKCS#7/CAdES blobs, fills
# placeholders in place (zero-padded to the reserved size, which
# openssl-grade verifiers tolerate), and verifies with OpenSSL-agreeing
# semantics. RSASSA-PSS, EdDSA and DSA fail loudly as unsupported;
# PKCS#12 input is declined (PEM/DER PKCS#8, PKCS#1 and SEC1 only).

proc hexEncode*(s: string): string =
  const digits = "0123456789abcdef"
  for c in s:
    result.add(digits[(ord(c) shr 4) and 0xF])
    result.add(digits[ord(c) and 0xF])

proc hexVal(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: pdfFail("hex string holds a non-digit")

proc hexDecode*(s: string): string =
  ## Even-length hex to bytes. Fails loudly on odd length or digits.
  if s.len mod 2 != 0:
    pdfFail("hex string has an odd length")
  var i = 0
  while i < s.len:
    result.add(char(hexVal(s[i]) * 16 + hexVal(s[i + 1])))
    i += 2

proc hashBytes*(digest, msg: string): string =
  ## Raw digest bytes for a CMS digest name.
  case digest
  of "sha256":
    let d = sha256(toBytes(msg))
    result = newString(32)
    for i in 0 ..< 32:
      result[i] = char(d[i])
  of "sha384":
    let d = sha384Algo.sha384(toBytes(msg))
    result = newString(48)
    for i in 0 ..< 48:
      result[i] = char(d[i])
  of "sha512":
    let d = sha512Algo.sha512(toBytes(msg))
    result = newString(64)
    for i in 0 ..< 64:
      result[i] = char(d[i])
  else:
    pdfFail("digest must be sha256, sha384 or sha512")

proc cmsDigestOid*(digest: string): seq[int] =
  case digest
  of "sha256": @[2, 16, 840, 1, 101, 3, 4, 2, 1]
  of "sha384": @[2, 16, 840, 1, 101, 3, 4, 2, 2]
  of "sha512": @[2, 16, 840, 1, 101, 3, 4, 2, 3]
  else: pdfFail("digest must be sha256, sha384 or sha512")

type
  Signer* = ref object of RootObj
    keyPem*: string ## private key, PEM or DER (PKCS#8, PKCS#1, SEC1)
    certChain*: seq[string] ## leaf first, each PEM or DER
    digest*: string ## "sha256" default ("sha384"/"sha512" for RSA)

  SignKey* = object
    case isEc*: bool
    of true:
      ec*: nimEcdsa.EcPrivateKey
    of false:
      rsa*: nimRsa.RsaPrivateKey

proc loadSignerKey*(keyPemOrDer: string): SignKey =
  ## Private key from PEM/DER: PKCS#8 (RSA/EC), PKCS#1 (RSA), or SEC1
  ## only when it carries its curve [0] (bare scalars fail loudly:
  ## the curve would have to be guessed).
  var der = keyPemOrDer
  if "-----BEGIN" in keyPemOrDer:
    der = pemToDer(keyPemOrDer)
  let top = derParse(der).derChildren()
  var isPkcs1 = top.len == 9
  if isPkcs1:
    for k in top:
      if k.tag != 0x02:
        isPkcs1 = false
  if isPkcs1:
    # PKCS#1 RSAPrivateKey: 9 INTEGERs.
    if top.len != 9:
      pdfFail("RSAPrivateKey is not 9 INTEGERs")
    for k in top:
      if k.tag != 0x02:
        pdfFail("RSAPrivateKey holds a non-INTEGER")
    let n = fromBytesBE(toBytes(intMagnitude(top[1].content)))
    return SignKey(isEc: false, rsa: nimRsa.RsaPrivateKey(
      n: n, e: fromBytesBE(toBytes(intMagnitude(top[2].content))),
      d: fromBytesBE(toBytes(intMagnitude(top[3].content))),
      p: fromBytesBE(toBytes(intMagnitude(top[4].content))),
      q: fromBytesBE(toBytes(intMagnitude(top[5].content))),
      dp: fromBytesBE(toBytes(intMagnitude(top[6].content))),
      dq: fromBytesBE(toBytes(intMagnitude(top[7].content))),
      qinv: fromBytesBE(toBytes(intMagnitude(top[8].content))),
      k: intMagnitude(top[1].content).len))
  if top.len == 3 and top[0].tag == 0x02 and top[1].tag == 0x30 and
      top[2].tag == 0x04:
    # PKCS#8 OneAsymmetricKey: version, algorithm, private key bytes.
    let algKids = top[1].derChildren()
    if algKids.len == 0 or algKids[0].tag != 0x06:
      pdfFail("private key algorithm has no OID")
    if algKids[0].content ==
        derOidContent([1, 2, 840, 113549, 1, 1, 1]):
      return loadSignerKey(top[2].content)
    if algKids[0].content !=
        derOidContent([1, 2, 840, 10045, 2, 1]):
      pdfFail("private key algorithm is not RSA or EC")
    if algKids.len < 2 or algKids[1].tag != 0x06:
      pdfFail("EC private key lacks its curve OID")
    let curve = ecCurveOf(algKids[1].content)
    let ecKids = getSeq(top[2].content, "ECPrivateKey")
    if ecKids.len < 2 or ecKids[0].tag != 0x02 or
        ecKids[1].tag != 0x04:
      pdfFail("ECPrivateKey is not version + privateKey")
    return SignKey(isEc: true, ec: nimEcdsa.EcPrivateKey(curve: curve,
      d: fromBytesBE(toBytes(ecKids[1].content))))
  if top.len >= 2 and top[0].tag == 0x02 and top[1].tag == 0x04:
    # Bare SEC1 ECPrivateKey: the curve must ride along as [0].
    var curveOid = ""
    for i in 2 ..< top.len:
      if top[i].tag == 0xA0:
        let inner = top[i].derChildren()
        if inner.len == 1 and inner[0].tag == 0x06:
          curveOid = inner[0].content
    if curveOid.len == 0:
      pdfFail("SEC1 private key lacks its curve [0] (use PKCS#8)")
    return SignKey(isEc: true,
      ec: nimEcdsa.EcPrivateKey(curve: ecCurveOf(curveOid),
        d: fromBytesBE(toBytes(top[1].content))))
  pdfFail("private key is not PKCS#8, PKCS#1 or SEC1")

proc certDerOf*(pemOrDer: string): string =
  ## One certificate as DER (passes DER through, decodes PEM).
  if "-----BEGIN" in pemOrDer:
    pemToDer(pemOrDer)
  else:
    pemOrDer

proc coordLenFor(curve: nimEcdsa.EcCurve): int =
  case curve
  of nimEcdsa.P256, nimEcdsa.Secp256k1: 32
  of nimEcdsa.P384: 48
  of nimEcdsa.P521: 66

proc ecDerSig(raw: openArray[byte], coordLen: int): string =
  ## Raw R||S to DER SEQ{INTEGER, INTEGER} with sign padding.
  if raw.len != 2 * coordLen:
    pdfFail("ECDSA signature has a bad length")
  var parts: seq[string] = @[]
  for h in 0 .. 1:
    var mag = newString(coordLen)
    for i in 0 ..< coordLen:
      mag[i] = char(raw[h * coordLen + i])
    while mag.len > 1 and mag[0] == '\0':
      mag = mag[1 .. ^1]
    if mag.len == 0:
      pdfFail("ECDSA signature component is zero")
    if byte(mag[0]) >= 0x80:
      mag = "\0" & mag
    parts.add(derIntBytes(mag))
  derSeq(parts)

proc bytesToString*(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b[i])

proc cmsSignBytes(key: SignKey, digest, msg: string): tuple[sig: string,
    sigDer: string] =
  ## Raw signature bytes + signatureAlgorithm OID + DER for CMS.
  if key.isEc:
    let want =
      case key.ec.curve
      of nimEcdsa.P256, nimEcdsa.Secp256k1: "sha256"
      of nimEcdsa.P384: "sha384"
      of nimEcdsa.P521: "sha512"
    if digest != "" and digest != want:
      pdfFail("ECDSA digest must match the key curve")
    let oid =
      case want
      of "sha256": @[1, 2, 840, 10045, 4, 3, 2]
      of "sha384": @[1, 2, 840, 10045, 4, 3, 3]
      else: @[1, 2, 840, 10045, 4, 3, 4]
    let raw = nimEcdsa.ecdsaSign(key.ec, msg)
    let coordLen = coordLenFor(key.ec.curve)
    (ecDerSig(raw, coordLen), derSeq(derOid(oid)))
  else:
    let h =
      case digest
      of "", "sha256": nimRsa.rhSha256
      of "sha384": nimRsa.rhSha384
      of "sha512": nimRsa.rhSha512
      else: pdfFail("digest must be sha256, sha384 or sha512")
    let oid =
      case digest
      of "", "sha256": @[1, 2, 840, 113549, 1, 1, 11]
      of "sha384": @[1, 2, 840, 113549, 1, 1, 12]
      else: @[1, 2, 840, 113549, 1, 1, 13]
    let raw = nimRsa.rsaPkcs1v15Sign(key.rsa, h, msg)
    (bytesToString(raw), derSeq(derOid(oid), derNull()))

proc buildCms*(signer: Signer, msg: string, cades: bool): string =
  ## Detached SignedData over `msg` (PAdES ByteRange bytes): PKCS#7
  ## without signed attributes, or CAdES-BES with contentType,
  ## messageDigest and signingTime (no signing-certificate attribute:
  ## documented divergence from strict CAdES-BES, which openssl does
  ## not require for verification either).
  if signer == nil:
    pdfFail("signer must not be nil")
  if signer.certChain.len == 0:
    pdfFail("signer needs at least the leaf certificate")
  let digest = if signer.digest.len == 0: "sha256" else: signer.digest
  discard cmsDigestOid(digest)
  let key = loadSignerKey(signer.keyPem)
  let leafDer = certDerOf(signer.certChain[0])
  let leaf = parseCert(leafDer)
  var certDers: seq[string] = @[]
  for c in signer.certChain:
    certDers.add(certDerOf(c))
  let msgHash = hashBytes(digest, msg)
  let digestAlgDer = derSeq(derOid(cmsDigestOid(digest)))
  var signedAttrsTlv = ""
  var sigInput = msg
  if cades:
    let attrs = derSeq(
      derSeq(derOid([1, 2, 840, 113549, 1, 9, 3]),
        derSet(derOid([1, 2, 840, 113549, 1, 7, 1]))),
      derSeq(derOid([1, 2, 840, 113549, 1, 9, 4]),
        derSet(derOctetString(msgHash))),
      derSeq(derOid([1, 2, 840, 113549, 1, 9, 5]),
        derSet(derUtcTime(now().utc))))
    signedAttrsTlv = derContext(0, true, derParse(attrs).content)
    # RFC 5652 5.4: the signature covers the SignedAttributes SET OF
    # encoding (tag 0x31), not the transmitted [0] IMPLICIT TLV. The
    # [0] form travels in the CMS; the SET form is what gets signed.
    sigInput = derTlv(dtSet, derParse(attrs).content)
  let (sig, sigAlgDer) = cmsSignBytes(key, digest, sigInput)
  var infoBody = derInt(1) &
    derSeq(leaf.issuerDer, derIntBytes(leaf.serial)) &
    digestAlgDer
  if cades:
    infoBody.add(signedAttrsTlv)
  infoBody.add(sigAlgDer)
  infoBody.add(derOctetString(sig))
  let signerInfo = derTlv(dtSequence, infoBody)
  var certBytes = ""
  for c in certDers:
    certBytes.add(c)
  let signedData = derSeq(derInt(1),
    derSet(digestAlgDer),
    derSeq(derOid([1, 2, 840, 113549, 1, 7, 1])),
    derContext(0, true, certBytes),
    derSet(signerInfo))
  derSeq(derOid([1, 2, 840, 113549, 1, 7, 2]),
    derExplicit(0, signedData))

proc coveredBytes*(file: string,
    byteRange: array[4, int]): string =
  ## ByteRange-covered bytes with the same bounds checks as
  ## verifyByteRangeHash. The /Contents gap stays out.
  let (o1, l1, o2, l2) = (byteRange[0], byteRange[1], byteRange[2],
    byteRange[3])
  if l1 < 0 or l2 < 0 or o1 < 0 or o2 < 0 or o1 + l1 > o2 or
      o2 + l2 > file.len:
    pdfFail("/ByteRange out of bounds for " & $file.len & " bytes")
  file[o1 ..< o1 + l1] & file[o2 ..< o2 + l2]

proc gapContents*(data: string, field: string,
    password = ""): tuple[cmsDer: string, sig: DocSignature,
    at, len: int] =
  ## CMS bytes from the /Contents hex gap, tolerating the zero padding
  ## in-place signing appends (trailing non-zero bytes fail loudly).
  var d = openDoc(data, defaultPdfLimits(), password)
  var found = false
  for s in d.docSignatures():
    if s.field == field:
      result.sig = s
      found = true
      break
  if not found:
    pdfFail("no signature field '" & field & "'")
  let sig = result.sig
  if not sig.hasByteRange:
    pdfFail("signature '" & field & "' has no /ByteRange")
  let (o1, l1, o2, l2) = (sig.byteRange[0], sig.byteRange[1],
    sig.byteRange[2], sig.byteRange[3])
  if l1 < 0 or l2 < 0 or o1 < 0 or o2 < 0 or o1 + l1 > o2 or
      o2 + l2 > data.len:
    pdfFail("signature '" & field & "' /ByteRange out of bounds")
  let ltPos = data.find('<', o1 + l1)
  if ltPos < 0 or ltPos >= o2:
    pdfFail("signature '" & field &
      "' /Contents hex not found in the gap")
  let gtPos = data.find('>', ltPos + 1)
  if gtPos < 0 or gtPos >= o2:
    pdfFail("signature '" & field &
      "' /Contents hex is unterminated")
  result.at = ltPos + 1
  result.len = gtPos - ltPos - 1
  let rawHex = hexDecode(data[ltPos + 1 ..< gtPos])
  var pp = 0
  let top = derRead(rawHex, pp)
  if top.tag != 0x30:
    pdfFail("CMS ContentInfo is not a SEQUENCE")
  for i in pp ..< rawHex.len:
    if rawHex[i] != '\0':
      pdfFail("CMS has trailing non-zero bytes")
  result.cmsDer = rawHex[0 ..< pp]

proc refreshMDate*(file: string, draft: SigDraft): string =
  ## Same-length /M refresh to the signing time. Offsets (and the
  ## ByteRange) are unchanged because the date format is fixed-width.
  result = file
  let mKey = "/M ("
  let mPos = result.find(mKey, draft.contentsAt + draft.contentsLen)
  if mPos < 0:
    pdfFail("internal error: /M lost from the signature dict")
  let mEnd = result.find(')', mPos + mKey.len)
  if mEnd < 0:
    pdfFail("internal error: unterminated /M date")
  let fresh = pdfDate()[1 .. ^2]
  if mEnd - (mPos + mKey.len) != fresh.len:
    pdfFail("internal error: /M date changed width")
  for i in 0 ..< fresh.len:
    result[mPos + mKey.len + i] = fresh[i]

proc fillContentsHex*(file: string, draft: SigDraft,
    cmsDer: string): SigDraft =
  ## Splice a CMS blob into the reserved hex span, zero-padding the
  ## remainder (openssl-grade verifiers tolerate the trailing zeros).
  ## The file length never changes, so the ByteRange stays valid.
  if draft.contentsAt < 0 or draft.contentsLen < 4 or
      draft.contentsAt + draft.contentsLen > file.len:
    pdfFail("signature draft span is out of bounds")
  if file[draft.contentsAt] != '<' or
      file[draft.contentsAt + draft.contentsLen - 1] != '>':
    pdfFail("signature draft span moved (tampered draft)")
  let reserved = (draft.contentsLen - 2) div 2
  if cmsDer.len > reserved:
    pdfFail("CMS blob (" & $cmsDer.len & " bytes) exceeds the " &
      "reserved " & $reserved & " bytes (recreate the placeholder " &
      "with a larger size)")
  var hex = hexEncode(cmsDer)
  while hex.len < reserved * 2:
    hex.add('0')
  var outFile = file
  for i in 0 ..< reserved * 2:
    outFile[draft.contentsAt + 1 + i] = hex[i]
  SigDraft(file: outFile, field: draft.field,
    byteRange: draft.byteRange, contentsAt: draft.contentsAt,
    contentsLen: draft.contentsLen, baseLen: draft.baseLen)

proc fillPlaceholder*(draft: SigDraft, cmsDer: string): SigDraft =
  ## Refresh /M to the signing time, then splice a CMS blob into the
  ## reserved hex span (zero-padded). The file length never changes,
  ## so every offset — and the ByteRange — stays valid. Fails when the
  ## blob does not fit or the span moved (tampered draft).
  fillContentsHex(refreshMDate(draft.file, draft), draft, cmsDer)

proc draftSubFilter*(draft: SigDraft): string =
  ## /SubFilter of the placeholder's Sig dict (resolved from the
  ## draft file). Fails when the field or value is missing.
  var d = openDoc(draft.file)
  for f in d.rawFields():
    if f.fullName == draft.field:
      let v = d.resolve(f.inh.v)
      if v.kind != coDict:
        pdfFail("signature field '" & draft.field & "' has no value")
      let s = v.dictGet("SubFilter")
      if s.kind != coName:
        pdfFail("signature field '" & draft.field &
          "' has no /SubFilter")
      return s.name
  pdfFail("signature field '" & draft.field & "' is gone")

proc signPlaceholder*(draft: SigDraft, signer: Signer): SigDraft =
  ## Fill the placeholder with a detached PKCS#7 signature. /M is
  ## refreshed first and the covered bytes are read after that, so
  ## the signature always matches the final file. The placeholder
  ## must carry adbe.pkcs7.detached.
  if draftSubFilter(draft) != "adbe.pkcs7.detached":
    pdfFail("placeholder SubFilter is not adbe.pkcs7.detached")
  let staged = refreshMDate(draft.file, draft)
  let msg = coveredBytes(staged, draft.byteRange)
  fillContentsHex(staged, draft, buildCms(signer, msg, false))

proc signPlaceholderCades*(draft: SigDraft, signer: Signer): SigDraft =
  ## Fill the placeholder with a CAdES-BES signature (same ordering
  ## guarantee as signPlaceholder). The placeholder must carry
  ## ETSI.CAdES.detached.
  if draftSubFilter(draft) != "ETSI.CAdES.detached":
    pdfFail("placeholder SubFilter is not ETSI.CAdES.detached")
  let staged = refreshMDate(draft.file, draft)
  let msg = coveredBytes(staged, draft.byteRange)
  fillContentsHex(staged, draft, buildCms(signer, msg, true))

type
  CmsSigned* = object
    digestOid*: string ## digestAlgorithm OID content bytes
    digestName*: string ## sha256/sha384/sha512/sha1
    encapType*: string ## eContentType OID content bytes
    hasContent*: bool ## attached content present (timestamp tokens)
    attachedContent*: string ## eContent OCTET STRING bytes ("" when detached)
    certs*: seq[Cert]
    certDers*: seq[string]
    issuerDer*: string ## SignerId issuer bytes
    serialContent*: string
    digestAlgDer*: string
    sigAlgDer*: string
    sigAlgOid*: string
    sigValue*: string ## OCTET STRING content bytes
    hasAttrs*: bool
    attrsDer*: string ## full [0] TLV as transmitted (signing input
      ## is the same content re-tagged as SET OF, RFC 5652 5.4)
    messageDigest*: string ## "" when no signed attributes
    unsignedDer*: string ## full [1] TLV ("" when absent)

proc parseCms*(cmsDer: string, allowAttached = false): CmsSigned =
  ## Structural parse shared by verification, timestamp tokens and
  ## DSS embedding. Exactly one SignerInfo is supported. Attached
  ## content fails unless `allowAttached` (timestamp tokens carry it).
  let ciKids = getSeq(cmsDer, "ContentInfo")
  if ciKids.len != 2 or ciKids[0].tag != 0x06:
    pdfFail("ContentInfo has no content type")
  if ciKids[0].content != derOidContent([1, 2, 840, 113549, 1, 7, 2]):
    pdfFail("ContentInfo is not signedData")
  if ciKids[1].tag != 0xA0:
    pdfFail("signedData is not [0] EXPLICIT")
  let sdKids = getSeq(ciKids[1].content, "SignedData")
  if sdKids.len < 4 or sdKids[0].tag != 0x02:
    pdfFail("SignedData is short a version")
  if sdKids[1].tag != 0x31:
    pdfFail("digestAlgorithms is not a SET")
  let daKids = sdKids[1].derChildren()
  if daKids.len == 0:
    pdfFail("digestAlgorithms is empty")
  let firstAlg = daKids[0].derChildren()
  if firstAlg.len == 0 or firstAlg[0].tag != 0x06:
    pdfFail("digestAlgorithm has no OID")
  result.digestOid = firstAlg[0].content
  if result.digestOid == derOidContent([2, 16, 840, 1, 101, 3, 4, 2, 1]):
    result.digestName = "sha256"
  elif result.digestOid ==
      derOidContent([2, 16, 840, 1, 101, 3, 4, 2, 2]):
    result.digestName = "sha384"
  elif result.digestOid ==
      derOidContent([2, 16, 840, 1, 101, 3, 4, 2, 3]):
    result.digestName = "sha512"
  elif result.digestOid == derOidContent([1, 3, 14, 3, 2, 26]):
    result.digestName = "sha1"
  else:
    pdfFail("unsupported CMS digest algorithm")
  result.digestAlgDer = ""
  # Re-sliced to the exact SET TLV below.
  if sdKids[2].tag != 0x30:
    pdfFail("encapContentInfo is not a SEQUENCE")
  let encKids = sdKids[2].derChildren()
  if encKids.len == 0 or encKids[0].tag != 0x06:
    pdfFail("encapContentInfo has no content type")
  result.encapType = encKids[0].content
  if encKids.len > 1:
    if not allowAttached:
      pdfFail("attached CMS content is not supported in PDF signatures")
    if encKids[1].tag != 0xA0:
      pdfFail("encapContent content is not [0] EXPLICIT")
    result.hasContent = true
    let econtent = derParse(encKids[1].content)
    if econtent.tag != 0x04:
      pdfFail("attached eContent is not an OCTET STRING")
    result.attachedContent = econtent.content
  var certIdx = 3
  if sdKids.len > 4 and sdKids[3].tag == 0xA0:
    var pos = 0
    while pos < sdKids[3].content.len:
      let start = pos
      discard derRead(sdKids[3].content, pos)
      let cder = sdKids[3].content[start ..< pos]
      result.certDers.add(cder)
      result.certs.add(parseCert(cder))
    certIdx = 4
  if sdKids.len <= certIdx or sdKids[certIdx].tag != 0x31:
    pdfFail("signerInfos is not a SET")
  var spos = 0
  let siNode = derRead(sdKids[certIdx].content, spos)
  if spos != sdKids[certIdx].content.len:
    pdfFail("only one CMS SignerInfo is supported")
  if siNode.tag != 0x30:
    pdfFail("SignerInfo is not a SEQUENCE")
  let siContent = siNode.content
  let si = siNode.derChildren()
  if si.len < 5 or si[0].tag != 0x02 or si[1].tag != 0x30 or
      si[2].tag != 0x30:
    pdfFail("SignerInfo is not version + sid + digestAlgorithm")
  let sid = si[1].derChildren()
  if sid.len != 2 or sid[0].tag != 0x30 or sid[1].tag != 0x02:
    pdfFail("signer sid is not issuerAndSerialNumber")
  result.serialContent = sid[1].content
  # Re-slice TLVs exactly (spans of the SignerInfo content).
  var spans: seq[tuple[off, len: int]] = @[]
  var qp = 0
  while qp < siContent.len:
    let s = qp
    discard derRead(siContent, qp)
    spans.add((s, qp - s))
  # spans: 0 version, 1 sid, 2 digestAlg, [3 attrs], -2 sigAlg, -1 sig.
  result.digestAlgDer = siContent[spans[2][0] ..<
    spans[2][0] + spans[2][1]]
  var rest = 3
  if si[rest].tag == 0xA0:
    result.hasAttrs = true
    result.attrsDer = siContent[spans[rest][0] ..<
      spans[rest][0] + spans[rest][1]]
    # Attributes live inside the [0] content.
    let attrSets = si[rest].derChildren()
    for a in attrSets:
      let ak = a.derChildren()
      if ak.len != 2 or ak[0].tag != 0x06 or ak[1].tag != 0x31:
        pdfFail("signed attribute is not OID + SET")
      if ak[0].content ==
          derOidContent([1, 2, 840, 113549, 1, 9, 4]):
        let mv = ak[1].derChildren()
        if mv.len != 1 or mv[0].tag != 0x04:
          pdfFail("messageDigest is not one OCTET STRING")
        result.messageDigest = mv[0].content
    rest += 1
  # Re-slice issuer Name TLV: first child of the sid SEQUENCE TLV.
  let sidTlv = siContent[spans[1][0] ..<
    spans[1][0] + spans[1][1]]
  var sp2 = 0
  let sidHead = derRead(sidTlv, sp2) # outer sid SEQ
  let sidBodyOff = sp2 - sidHead.content.len
  var np = 0
  discard derRead(sidTlv[sidBodyOff .. ^1], np)
  result.issuerDer = sidTlv[sidBodyOff ..< sidBodyOff + np]
  if si[rest].tag != 0x30:
    pdfFail("SignerInfo signatureAlgorithm is not a SEQUENCE")
  let saKids = si[rest].derChildren()
  if saKids.len == 0 or saKids[0].tag != 0x06:
    pdfFail("signatureAlgorithm has no OID")
  result.sigAlgOid = saKids[0].content
  result.sigAlgDer = siContent[spans[rest][0] ..<
    spans[rest][0] + spans[rest][1]]
  rest += 1
  if si[rest].tag != 0x04:
    pdfFail("SignerInfo signature is not an OCTET STRING")
  result.sigValue = si[rest].content
  rest += 1
  if rest < si.len:
    if si[rest].tag != 0xA1:
      pdfFail("SignerInfo trails with a non-[1] tag")
    result.unsignedDer = siContent[spans[rest][0] ..<
      spans[rest][0] + spans[rest][1]]
    if rest + 1 != si.len:
      pdfFail("SignerInfo has trailing data")

type
  VerifyResult* = object
    valid*: bool
    digestOk*: bool
    sigOk*: bool
    chainOk*: bool
    trusted*: bool
    covered*: int
    signer*: Cert
    signedAt*: DateTime
    hasSignedAt*: bool
    notBefore*: DateTime
    notAfter*: DateTime
    warnings*: seq[string]
    errors*: seq[string]

proc rsaHashFor(digestName: string): nimRsa.RsaHash =
  case digestName
  of "sha256": nimRsa.rhSha256
  of "sha384": nimRsa.rhSha384
  of "sha512": nimRsa.rhSha512
  of "sha1": nimRsa.rhSha1
  else: pdfFail("unsupported CMS digest")

proc orderChain(leaf: Cert, others: seq[Cert]): seq[Cert] =
  ## Leaf-first chain by issuer/subject links; stops at the first gap.
  result = @[leaf]
  var rest = others
  while true:
    var found = -1
    for i, c in rest:
      if namesMatch(result[^1].issuer, c.subject):
        found = i
        break
    if found < 0:
      break
    result.add(rest[found])
    rest.delete(found)

proc verifySignature*(data: string, field: string,
    trust: seq[string] = @[], password = ""): VerifyResult =
  ## Full PAdES check in ByteRange order, collecting every failure
  ## instead of short-circuiting: /ByteRange bounds, CMS parse, digest
  ## vs messageDigest, cryptographic signature, chain to `trust`.
  ## `trust` holds DER-or-PEM certificates. Without trust anchors the
  ## chain cannot validate (chainOk false) while digestOk/sigOk still
  ## report integrity. `valid` needs all three true.
  result = VerifyResult()
  var gap: tuple[cmsDer: string, sig: DocSignature, at, len: int]
  try:
    gap = gapContents(data, field, password)
  except PdfError as e:
    result.errors.add(e.msg)
    return
  let sig = gap.sig
  result.covered = sig.byteRange[1] + sig.byteRange[3]
  let covered = data[sig.byteRange[0] ..<
      sig.byteRange[0] + sig.byteRange[1]] &
    data[sig.byteRange[2] ..< sig.byteRange[2] + sig.byteRange[3]]
  let cmsDer = gap.cmsDer
  var cms: CmsSigned
  try:
    cms = parseCms(cmsDer)
  except PdfError as e:
    result.errors.add("CMS does not parse (" & e.msg & ")")
    return
  if cms.encapType != derOidContent([1, 2, 840, 113549, 1, 7, 1]):
    result.errors.add("CMS content is not pkcs7-data")
    return
  # Leaf = the CMS cert matching the SignerId.
  var leafOk = false
  var leaf: Cert
  for c in cms.certs:
    if c.issuerDer == cms.issuerDer and
        c.serial == cms.serialContent:
      leaf = c
      leafOk = true
      break
  if not leafOk:
    result.errors.add("signer certificate not in the CMS")
    return
  result.signer = leaf
  result.notBefore = leaf.validity.notBefore
  result.notAfter = leaf.validity.notAfter
  if sig.signDate.len > 0:
    let pd = parsePdfDate(sig.signDate)
    if pd.ok:
      try:
        result.signedAt = dateTime(pd.year, Month(pd.month),
          MonthdayRange(pd.day), HourRange(pd.hour),
          MinuteRange(pd.minute), SecondRange(pd.second), 0, utc())
        result.hasSignedAt = true
      except RangeDefect, ValueError:
        result.warnings.add("unparseable /M date")
    else:
      result.warnings.add("unparseable /M date")
  var at = now().utc
  if result.hasSignedAt:
    at = result.signedAt
  else:
    result.warnings.add("no /M date; validating at the current time")
  # Digest over the covered bytes.
  if cms.hasAttrs:
    if cms.messageDigest.len == 0:
      result.errors.add("signed attributes lack a messageDigest")
    elif hashBytes(cms.digestName, covered) != cms.messageDigest:
      result.errors.add("messageDigest does not match the covered bytes")
      result.digestOk = false
    else:
      result.digestOk = true
  else:
    result.digestOk = true # vacuous: integrity rides on the signature
  # Cryptographic signature. CAdES input is the SignedAttributes
  # SET OF encoding (RFC 5652 5.4), not the transmitted [0] TLV.
  let sigMsg =
    if cms.hasAttrs: derTlv(dtSet, derParse(cms.attrsDer).content)
    else: covered
  try:
    if leaf.spki.isRsa:
      let pub = rsaPublicKeyFromSpki(leaf.spki)
      if cms.sigAlgOid ==
          derOidContent([1, 2, 840, 113549, 1, 1, 10]):
        let (ph, saltLen) = parseRsaPssParams(cms.sigAlgDer)
        if saltLen != hashLenOf(ph):
          pdfFail("PSS salt length is not the digest length")
        result.sigOk = nimRsa.rsaPssVerify(pub, ph, toBytes(sigMsg),
          toBytes(cms.sigValue))
        if ph == nimRsa.rhSha1:
          result.warnings.add("weak signature sha1RSA-PSS")
      else:
        result.sigOk = nimRsa.rsaPkcs1v15Verify(pub,
          rsaHashFor(cms.digestName), toBytes(sigMsg),
          toBytes(cms.sigValue))
    elif leaf.spki.isEc:
      let curve = ecCurveOf(leaf.spki.curve)
      let coordLen =
        case curve
        of nimEcdsa.P256, nimEcdsa.Secp256k1: 32
        of nimEcdsa.P384: 48
        of nimEcdsa.P521: 66
      let pub = ecPublicKeyFromSpki(leaf.spki)
      if not nimEcdsa.ecValidatePublicKey(pub):
        result.errors.add("signer EC key fails validation")
      else:
        result.sigOk = nimEcdsa.ecdsaVerify(pub, sigMsg,
          derSigToRaw(cms.sigValue, coordLen))
    else:
      result.errors.add("signer key is not RSA or EC")
  except PdfError as e:
    result.errors.add("signature check failed (" & e.msg & ")")
  # Chain to the trust anchors.
  var trustCerts: seq[Cert] = @[]
  var trustBad = false
  for t in trust:
    try:
      trustCerts.add(parseCert(certDerOf(t)))
    except PdfError as e:
      result.errors.add("trust anchor does not parse (" & e.msg & ")")
      trustBad = true
  if not trustBad:
    var others: seq[Cert] = @[]
    for c in cms.certs:
      if c.raw != leaf.raw:
        others.add(c)
    let reasons = checkChain(orderChain(leaf, others), trustCerts, at)
    if reasons.len == 0:
      result.chainOk = true
      result.trusted = true
    else:
      result.errors.add(reasons)
  # Warnings (never affect ok-flags).
  if cms.digestName == "sha1":
    result.warnings.add("weak digest sha1")
  if cms.sigAlgOid == derOidContent([1, 2, 840, 113549, 1, 1, 5]):
    result.warnings.add("weak signature sha1RSA")
  if sig.subFilter == "ETSI.CAdES.detached" and not cms.hasAttrs:
    result.warnings.add("CAdES filter without signed attributes")
  elif sig.subFilter != "adbe.pkcs7.detached" and
      sig.subFilter != "ETSI.CAdES.detached":
    result.warnings.add("unknown SubFilter '" & sig.subFilter & "'")
  result.valid = result.digestOk and result.sigOk and result.chainOk

# ---------------------------------------------------------------------------
# Timestamps B-T (P6): RFC 3161 over HTTP, behind a caller callback so
# the package stays I/O-free.
# ---------------------------------------------------------------------------

type
  TsaClient* = proc(url, body: string): string
    ## POSTs a TimeStampReq, returns the TimeStampResp bytes. Network,
    ## auth and retry policy belong to the caller.

proc buildTimestampReq*(sigValue: string): string =
  ## TimeStampReq for the sha256 messageImprint of a signature value.
  derSeq(derInt(1),
    derSeq(derSeq(derOid([2, 16, 840, 1, 101, 3, 4, 2, 1])),
      derOctetString(hashBytes("sha256", sigValue))),
    derBool(true))

proc parseTstInfo(parsed: CmsSigned, sigValue: string): DateTime =
  ## TSTInfo checks: eContentType is tstInfo, imprint matches
  ## sha256(sigValue) under sha256, genTime parsed.
  if parsed.encapType !=
      derOidContent([1, 2, 840, 113549, 1, 9, 16, 1, 4]):
    pdfFail("timestamp token content is not tstInfo")
  if not parsed.hasContent:
    pdfFail("timestamp token carries no TSTInfo")
  let tst = parsed.attachedContent
  let kids = getSeq(tst, "TSTInfo")
  if kids.len < 5 or kids[0].tag != 0x02 or kids[1].tag != 0x06 or
      kids[2].tag != 0x30:
    pdfFail("TSTInfo is not version + policy + messageImprint")
  let mi = kids[2].derChildren()
  if mi.len != 2 or mi[0].tag != 0x30 or mi[1].tag != 0x04:
    pdfFail("TSTInfo messageImprint is not alg + hash")
  let algKids = mi[0].derChildren()
  if algKids.len == 0 or algKids[0].tag != 0x06 or
      algKids[0].content != derOidContent([2, 16, 840, 1, 101, 3, 4, 2, 1]):
    pdfFail("timestamp imprint digest is not sha256")
  if mi[1].content != hashBytes("sha256", sigValue):
    pdfFail("timestamp imprint does not match the signature")
  if kids[4].tag != 0x18:
    pdfFail("TSTInfo genTime is not GeneralizedTime")
  parseDerTime(kids[4].tag, kids[4].content)

proc parseTimestampResp*(resp, sigValue: string): tuple[token: string,
    genTime: DateTime] =
  ## TimeStampResp with a granted token whose imprint matches
  ## sha256(sigValue). Fails loudly on any other status, on imprint
  ## mismatch, or on malformed tokens. TSA *trust* is the caller's:
  ## use verifyTimestampToken with trust anchors to check the token.
  let outer = derParse(resp)
  if outer.tag != 0x30:
    pdfFail("TimeStampResp is not a SEQUENCE")
  let top = outer.derChildren()
  if top.len != 2 or top[0].tag != 0x30:
    pdfFail("TimeStampResp is not status + token")
  let stKids = top[0].derChildren()
  if stKids.len == 0 or stKids[0].tag != 0x02:
    pdfFail("TimeStampResp status is not an INTEGER")
  if stKids[0].content != "\0" and stKids[0].content != "\x01":
    pdfFail("timestamp authority did not grant the token")
  if top[1].tag != 0x30:
    pdfFail("TimeStampResp token is not a ContentInfo")
  let tokenOff = outer.total - outer.content.len + top[0].total
  let token = resp[tokenOff ..< outer.total]
  result.token = token
  let parsed = parseCms(token, allowAttached = true)
  if parsed.digestName != "sha256":
    pdfFail("timestamp token digest is not sha256")
  result.genTime = parseTstInfo(parsed, sigValue)

proc verifyTimestampToken*(token, sigValue: string,
    trust: seq[string]): tuple[ok: bool, genTime: DateTime,
    warnings: seq[string]] =
  ## Token imprint match plus full CMS check (signature + chain at
  ## genTime). Trust anchors required, as in verifySignature.
  let parsed = parseCms(token, allowAttached = true)
  let genTime = parseTstInfo(parsed, sigValue)
  var trustCerts: seq[Cert] = @[]
  for t in trust:
    try:
      trustCerts.add(parseCert(certDerOf(t)))
    except PdfError as e:
      return (false, genTime, @["trust anchor does not parse (" &
        e.msg & ")"])
  var leafOk = false
  var leaf: Cert
  for c in parsed.certs:
    if c.issuerDer == parsed.issuerDer and
        c.serial == parsed.serialContent:
      leaf = c
      leafOk = true
      break
  if not leafOk:
    return (false, genTime, @["token signer cert not in the token"])
  var warnings: seq[string] = @[]
  let msg =
    if parsed.hasAttrs: derTlv(dtSet, derParse(parsed.attrsDer).content)
    else: parsed.attachedContent
  var sigOk = false
  try:
    if leaf.spki.isRsa:
      let pub = rsaPublicKeyFromSpki(leaf.spki)
      if parsed.sigAlgOid ==
          derOidContent([1, 2, 840, 113549, 1, 1, 10]):
        let (ph, saltLen) = parseRsaPssParams(parsed.sigAlgDer)
        if saltLen != hashLenOf(ph):
          return (false, genTime,
            @["PSS salt length is not the digest length"])
        sigOk = nimRsa.rsaPssVerify(pub, ph, toBytes(msg),
          toBytes(parsed.sigValue))
        if ph == nimRsa.rhSha1:
          warnings.add("weak signature sha1RSA-PSS")
      else:
        sigOk = nimRsa.rsaPkcs1v15Verify(pub,
          rsaHashFor(parsed.digestName), toBytes(msg),
          toBytes(parsed.sigValue))
    elif leaf.spki.isEc:
      let curve = ecCurveOf(leaf.spki.curve)
      let coordLen =
        case curve
        of nimEcdsa.P256, nimEcdsa.Secp256k1: 32
        of nimEcdsa.P384: 48
        of nimEcdsa.P521: 66
      let pub = ecPublicKeyFromSpki(leaf.spki)
      if nimEcdsa.ecValidatePublicKey(pub):
        sigOk = nimEcdsa.ecdsaVerify(pub, msg,
          derSigToRaw(parsed.sigValue, coordLen))
    if parsed.digestName == "sha1":
      warnings.add("weak digest sha1")
  except PdfError as e:
    return (false, genTime, @["token signature check failed (" &
      e.msg & ")"])
  if not sigOk:
    return (false, genTime, warnings)
  var others: seq[Cert] = @[]
  for c in parsed.certs:
    if c.raw != leaf.raw:
      others.add(c)
  let reasons = checkChain(orderChain(leaf, others), trustCerts,
    genTime, "1.3.6.1.5.5.7.3.8")
  if reasons.len > 0:
    return (false, genTime, warnings & reasons)
  (true, genTime, warnings)

proc requestTimestamp*(sigValue, tsaUrl: string,
    post: TsaClient): tuple[token: string, genTime: DateTime] =
  ## POST a TimeStampReq and parse the granted token. HTTP stays
  ## behind `post`; failures (transport, status, imprint) raise.
  parseTimestampResp(post(tsaUrl, buildTimestampReq(sigValue)),
    sigValue)

proc embedTimestamp*(signedFile, field, token: string): string =
  ## New signature-dict revision carrying the token as an unsigned
  ## signature-time-stamp attribute (1.2.840.113549.1.9.16.2.14). The
  ## ByteRange never changes, so the original signature still
  ## verifies: the longer /Contents lives in appended bytes only.
  let gap = gapContents(signedFile, field)
  let cms = parseCms(gap.cmsDer)
  # The token travels whole (a ContentInfo) inside the unsigned attrs.
  let unsignedTlv = derContext(1, true, derSeq(
    derSeq(derOid([1, 2, 840, 113549, 1, 9, 16, 2, 14]),
      derSet(token))))
  var infoBody = derInt(1) &
    derSeq(derSeq(cms.issuerDer, derIntBytes(cms.serialContent))) &
    cms.digestAlgDer
  if cms.hasAttrs:
    infoBody.add(cms.attrsDer)
  infoBody.add(cms.sigAlgDer)
  infoBody.add(derOctetString(cms.sigValue))
  infoBody.add(unsignedTlv)
  let siTlv = derTlv(dtSequence, infoBody)
  # Rebuild the SignedData with the timestamped SignerInfo. Codec
  # limits: exactly one certificate set and one signer are preserved
  # from the parsed CMS; exotic shapes fail loudly in parseCms first.
  var certBytes = ""
  for c in cms.certDers:
    certBytes.add(c)
  let signedData = derSeq(derInt(1),
    derSet(cms.digestAlgDer),
    derSeq(derOid([1, 2, 840, 113549, 1, 7, 1])),
    derContext(0, true, certBytes),
    derSet(siTlv))
  let contentInfo = derSeq(derOid([1, 2, 840, 113549, 1, 7, 2]),
    derExplicit(0, signedData))
  var d = openDoc(signedFile)
  var sigRef = CosObj(kind: coNull)
  for f in d.rawFields():
    if f.fullName == field:
      let v = d.resolve(f.inh.v)
      if v.kind != coDict:
        pdfFail("signature field '" & field & "' has no value")
      # Locate the indirect Sig dict through the field value.
      var fr = f.inh.v
      if fr.kind == coRef:
        sigRef = fr
      break
  if sigRef.kind != coRef:
    pdfFail("signature value is not indirect (cannot timestamp)")
  let old = d.resolve(sigRef)
  if old.kind != coDict:
    pdfFail("signature field '" & field & "' has no value")
  var keys = old.keys
  var vals = old.vals
  var sawContents = false
  for i, k in keys:
    if k == "Contents":
      # Hex-string placeholder: writeCos would parenthesize, so a
      # sentinel is substituted with angle brackets afterwards.
      vals[i] = CosObj(kind: coStr, sval: "CONTENTSHEX" & $i)
      sawContents = true
  if not sawContents:
    pdfFail("signature dict has no /Contents")
  var u = beginUpdate(signedFile)
  var body = writeCos(CosObj(kind: coDict, keys: keys, vals: vals))
  for i, k in keys:
    if k == "Contents":
      let sent = "(CONTENTSHEX" & $i & ")"
      let at = body.find(sent)
      if at < 0:
        pdfFail("internal error: Contents sentinel lost")
      body = body[0 ..< at] & "<" & hexEncode(contentInfo) & ">" &
        body[at + sent.len .. ^1]
  discard u.updateObject(sigRef.refNum, body)
  u.finishUpdate()

# ---------------------------------------------------------------------------
# Document Security Store, certificates only (P7, transport scope).
# ---------------------------------------------------------------------------
#
# embedDssCerts carries validation certificates (chain + trust extras)
# in the catalog /DSS with per-signature /VRI entries so offline
# readers can rebuild chains. It is transport, not trust: without
# OCSP/CRL revocation data (deferred: needs OCSP/CRL ASN.1 plus an
# HTTP ecosystem, and no network in tests) this does NOT confer LTV.
# A DSS with only certificates and no revocation data must never be
# presented as long-term validation.

proc embedDssCerts*(signedFile: string,
    certDers: seq[string]): string =
  ## Incremental update adding certificate streams to /DSS /Certs
  ## (deduplicated by bytes) plus a /VRI entry per signed signature.
  ## VRI keys are the uppercase hex SHA-256 of the signature's
  ## /Contents bytes (ETSI EN 319 142-1 5.4). Merges with an existing
  ## /DSS when present.
  if certDers.len == 0:
    pdfFail("no certificates to embed")
  var u = beginUpdate(signedFile)
  var d = openDoc(u.base, u.limits)
  var certNums: seq[int] = @[]
  var seen: seq[string] = @[]
  var existing: seq[string] = @[]
  let cat = d.catalog()
  let dssOld = cat.dictGet("DSS")
  if dssOld.kind == coRef or dssOld.kind == coDict:
    var dssv = dssOld
    if dssv.kind == coRef:
      dssv = d.resolve(dssv)
    if dssv.kind == coDict:
      let cl = dssv.dictGet("Certs")
      if cl.kind == coArray:
        for c in cl.items:
          let r = d.resolve(c)
          if r.kind == coStream:
            existing.add(r.raw)
  for c in certDers:
    if c in existing or c in seen:
      continue
    seen.add(c)
    certNums.add(u.addObject(writeCos(CosObj(kind: coStream,
      streamDict: @["Length"],
      streamVals: @[CosObj(kind: coInt, ival: c.len)], raw: c))))
  let dssNum =
    block:
      var n = -1
      if dssOld.kind == coRef:
        n = dssOld.refNum
      elif dssOld.kind == coDict:
        n = u.nextNum
        inc u.nextNum
      else:
        n = u.nextNum
        inc u.nextNum
      n
  # /Certs array: existing refs plus new numbers.
  var certRefs: seq[CosObj] = @[]
  if dssOld.kind != coNull:
    var dssv = dssOld
    if dssv.kind == coRef:
      dssv = d.resolve(dssv)
    if dssv.kind == coDict:
      let cl = dssv.dictGet("Certs")
      if cl.kind == coArray:
        for c in cl.items:
          if c.kind == coRef:
            certRefs.add(c)
  for n in certNums:
    certRefs.add(CosObj(kind: coRef, refNum: n, refGen: 0))
  # /VRI: one entry per signed signature in the file.
  var vriKeys: seq[string] = @[]
  var vriVals: seq[CosObj] = @[]
  if dssOld.kind != coNull:
    var dssv = dssOld
    if dssv.kind == coRef:
      dssv = d.resolve(dssv)
    if dssv.kind == coDict:
      let v = dssv.dictGet("VRI")
      if v.kind == coDict:
        vriKeys = v.keys
        vriVals = v.vals
  for s in d.docSignatures():
    if not s.signed:
      continue
    let gap = gapContents(signedFile, s.field)
    let key = hexEncode(hashBytes("sha256", gap.cmsDer)).toUpperAscii()
    var found = false
    for i, k in vriKeys:
      if k == key:
        vriVals[i] = CosObj(kind: coDict, keys: @["Cert"],
          vals: @[CosObj(kind: coArray, items: certRefs)])
        found = true
    if not found:
      vriKeys.add(key)
      vriVals.add(CosObj(kind: coDict, keys: @["Cert"],
        vals: @[CosObj(kind: coArray, items: certRefs)]))
  let dssBody = writeCos(CosObj(kind: coDict,
    keys: @["Certs", "VRI"],
    vals: @[CosObj(kind: coArray, items: certRefs),
      CosObj(kind: coDict, keys: vriKeys, vals: vriVals)]))
  discard u.updateObject(dssNum, dssBody)
  if dssOld.kind != coRef:
    # Point the catalog at the DSS (new or previously direct object).
    let catNow = d.catalog()
    var ckeys = catNow.keys
    var cvals = catNow.vals
    var replaced = false
    for i, k in ckeys:
      if k == "DSS":
        cvals[i] = CosObj(kind: coRef, refNum: dssNum, refGen: 0)
        replaced = true
    if not replaced:
      ckeys.add("DSS")
      cvals.add(CosObj(kind: coRef, refNum: dssNum, refGen: 0))
    discard u.updateObject(u.rootNum, writeCos(CosObj(kind: coDict,
      keys: ckeys, vals: cvals)))
  u.finishUpdate()
