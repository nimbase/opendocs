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
import ./types
import ./cos
import ./docmodel
import ./write
import ./forms

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
    size = 8192): SigDraft =
  ## Append an unsigned signature shell: /Sig dict with zeroed
  ## /Contents (`size` bytes as hex) and a /ByteRange patched to the
  ## final offsets, plus an /FT /Sig field (no widget: invisible
  ## signature). Joins the existing /AcroForm or creates one.
  ## Returns the file plus the content span for the external signer.
  if fieldName.len == 0:
    pdfFail("signature field name must not be empty")
  if size <= 0 or size > 1_000_000:
    pdfFail("signature placeholder size out of range (1..1000000)")
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
  let sigBody = "<< /Type /Sig /Filter /Adobe.PPKLite " &
    "/SubFilter /adbe.pkcs7.detached " & brHolder & " /Contents <" &
    hex & "> /M " & pdfDate() & " >>"
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
  # zeros keep their width, so offsets stay valid.
  let holder = "/ByteRange [" & byteRangeSlot & " " & byteRangeSlot &
    " " & byteRangeSlot & " " & byteRangeSlot & "]"
  let brPos = file.find(holder)
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
    contentsAt: ltPos, contentsLen: gtPos + 1 - ltPos)
