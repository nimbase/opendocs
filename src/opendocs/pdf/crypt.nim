## PDF encryption (ISO 32000 §7.6): Standard filter, V 1/2/4/5.
##
## R 2/3 (V1/V2): RC4 with MD5-derived file key, user/owner auth per
## Algorithms 2-7. R 4 (V4): crypt filters (/V2 RC4, /AESV2 with random
## IV prefix) selected per class by /StmF and /StrF, Identity default.
## R 6 (V5): SHA-256 user/owner validation, AES-256-ECB-wrapped file
## key, AES-256-CBC data (AESV3), Perms check. R 5 was retired and is
## rejected with a clear error.
##
## Only direct COS values are decrypted here; docmodel.resolve feeds
## each indirect object through decryptObj exactly once. The /Encrypt
## dictionary itself (O/U/OE/UE) is never decrypted.

import std/strutils
import nimcypher/algos/rc4
import nimcypher/algos/aes
import nimcypher/algos/sha256
import nimcypher/hashes/md5
import ./types
import ./lexer
import ./cos

type
  CryptClass* = enum
    ccNone, ccRC4, ccAESV2, ccAESV3

  PdfCrypt* = object
    present*: bool
    v*: int
    r*: int
    keyLen*: int ## file-key bytes (R<6)
    fileKey*: string ## raw key bytes
    stmCrypt*: CryptClass
    strCrypt*: CryptClass
    encryptMetadata*: bool
    encryptObjNum*: int ## /Encrypt object number (-1 when direct)

const cryptPad* =
  "\x28\xBF\x4E\x5E\x4E\x75\x8A\x41\x64\x00\x4E\x56\xFF\xFA\x01\x08" &
  "\x2E\x2E\x00\xB6\xD0\x68\x3E\x80\x2F\x0C\xA9\xFE\x64\x53\x69\x7A"

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b[i])

proc md5raw(s: string): string =
  toStr(md5(toBytes(s)))

proc sha256raw(s: string): string =
  toStr(sha256(toBytes(s)))

proc rc4s(key, data: string): string =
  if data.len == 0:
    return ""
  toStr(rc4Crypt(toBytes(key), toBytes(data)))

proc rc4xor1(key: string, n: int): string =
  ## Key with every byte XORed by the iteration counter (Algs 3-6).
  result = newString(key.len)
  for i in 0 ..< key.len:
    result[i] = char(byte(key[i]) xor byte(n))

proc aesCbcDec*(key, data: string): string =
  ## IV-prefixed AES-CBC (16-byte key for AESV2, 32 for AESV3).
  ## Strips the random padding named by the last byte.
  if data.len == 0:
    return ""
  if data.len < 16 or data.len mod 16 != 0:
    pdfFail("AES-encrypted data length " & $data.len & " is not a " &
      "positive multiple of 16")
  var iv: array[16, byte]
  for i in 0 ..< 16:
    iv[i] = byte(data[i])
  var ctx = initAes(toBytes(key))
  let plain = toStr(ctx.cbcDecryptOne(iv, toBytes(data[16 .. ^1])))
  let n = int(byte(plain[^1]))
  if n < 1 or n > 16 or n > plain.len:
    pdfFail("bad AES padding length " & $n)
  plain[0 ..< plain.len - n]

proc aesEcbDec*(key, data: string): string =
  if data.len == 0 or data.len mod 16 != 0:
    pdfFail("AES-ECB data length " & $data.len &
      " is not a positive multiple of 16")
  var ctx = initAes(toBytes(key))
  toStr(ctx.ecbDecrypt(toBytes(data)))

proc aesCbcEnc*(key, iv, data: string): string =
  ## IV-prefixed AES-CBC for fixture generation (PKCS#7-style padding).
  if iv.len != 16:
    pdfFail("AES-CBC needs a 16-byte IV")
  let n = 16 - data.len mod 16
  var payload = data
  for _ in 1 .. n:
    payload.add(char(n))
  var ivArr: array[16, byte]
  for i in 0 ..< 16:
    ivArr[i] = byte(iv[i])
  var ctx = initAes(toBytes(key))
  iv & toStr(ctx.cbcEncryptOne(ivArr, toBytes(payload)))

proc aesEcbEnc*(key, data: string): string =
  ## AES-ECB for fixture generation (R6 OE/UE/Perms wrapping).
  if data.len == 0 or data.len mod 16 != 0:
    pdfFail("AES-ECB data length " & $data.len &
      " is not a positive multiple of 16")
  var ctx = initAes(toBytes(key))
  toStr(ctx.ecbEncrypt(toBytes(data)))

proc objectKey(c: PdfCrypt, objNum, gen: int, salted: bool): string =
  ## Per-object key, Algorithm 1. Three low object bytes plus two
  ## generation bytes, "sAlT" appended for AESV2, MD5, first n bytes.
  var m = c.fileKey
  m.add(char(objNum and 0xFF))
  m.add(char((objNum shr 8) and 0xFF))
  m.add(char((objNum shr 16) and 0xFF))
  m.add(char(gen and 0xFF))
  m.add(char((gen shr 8) and 0xFF))
  if salted:
    m.add("sAlT")
  let h = md5raw(m)
  h[0 ..< min(c.keyLen + 5, 16)]

proc decryptData*(c: PdfCrypt, objNum, gen: int, data: string,
    cls: CryptClass): string =
  ## Decrypt one stream body or string with an explicit class.
  case cls
  of ccNone:
    data
  of ccRC4:
    rc4s(c.objectKey(objNum, gen, false), data)
  of ccAESV2:
    aesCbcDec(c.objectKey(objNum, gen, true), data)
  of ccAESV3:
    aesCbcDec(c.fileKey, data)

proc decryptValue*(c: PdfCrypt, val: CosObj, objNum, gen: int,
    strCls: CryptClass): CosObj =
  ## Deep-decrypt strings inside a resolved non-stream value.
  case val.kind
  of coStr:
    CosObj(kind: coStr,
      sval: c.decryptData(objNum, gen, val.sval, strCls))
  of coArray:
    var items = newSeq[CosObj](val.items.len)
    for i, it in val.items:
      items[i] = c.decryptValue(it, objNum, gen, strCls)
    CosObj(kind: coArray, items: items)
  of coDict:
    var vals = newSeq[CosObj](val.vals.len)
    for i, v in val.vals:
      vals[i] = c.decryptValue(v, objNum, gen, strCls)
    CosObj(kind: coDict, keys: val.keys, vals: vals)
  else:
    val

proc paddedPw(password: string): string =
  ## Password padded/truncated to 32 bytes (Algorithm 2 step a).
  if password.len >= 32:
    password[0 ..< 32]
  else:
    password & cryptPad[0 ..< 32 - password.len]

proc le32(v: int): string =
  let u = uint32(v and 0xFFFFFFFF)
  result = newString(4)
  result[0] = char(u and 0xFF)
  result[1] = char((u shr 8) and 0xFF)
  result[2] = char((u shr 16) and 0xFF)
  result[3] = char((u shr 24) and 0xFF)

proc fileKeyR26(password, o: string, p: int, idFirst: string,
    keyLen, r: int, encryptMeta: bool): string =
  ## File key, Algorithm 2: MD5 over padded password, O, P, ID and the
  ## metadata flag, then 50 extra rounds over the first n bytes for R>=3.
  var m = paddedPw(password) & o & le32(p) & idFirst
  if r >= 4 and not encryptMeta:
    m.add("\xFF\xFF\xFF\xFF")
  var h = md5raw(m)
  if r >= 3:
    for _ in 1 .. 50:
      h = md5raw(h[0 ..< keyLen])
  h[0 ..< keyLen]

proc authFail(password: string): PdfCrypt =
  if password.len == 0:
    pdfFail("encrypted PDF: password required " &
      "(pass password to readPdfBytes/openPdf)")
  pdfFail("wrong password for encrypted PDF")

proc computeO*(owner, user: string, keyLen, r: int): string =
  ## Owner value for fixture generation and tests (Algorithm 3).
  var key = md5raw(paddedPw(owner))[0 ..< keyLen]
  result = rc4s(key, paddedPw(user))
  if r >= 3:
    for i in 1 .. 19:
      result = rc4s(rc4xor1(key, i), result)

proc computeU*(fileKey, idFirst: string, keyLen, r: int): string =
  ## User value for fixture generation and tests (Algorithms 4-5).
  if r == 2:
    rc4s(fileKey, cryptPad)
  else:
    var c = rc4s(fileKey, md5raw(cryptPad & idFirst))
    for i in 1 .. 19:
      c = rc4s(rc4xor1(fileKey, i), c)
    c & newString(16)

proc userOk(fileKey, u, idFirst: string, r: int): bool =
  if r == 2:
    rc4s(fileKey, cryptPad) == u
  else:
    var c = rc4s(fileKey, md5raw(cryptPad & idFirst))
    for i in 1 .. 19:
      c = rc4s(rc4xor1(fileKey, i), c)
    u.len >= 16 and c == u[0 ..< 16]

proc ownerUserPw(o, password: string, keyLen, r: int): string =
  ## Recover the padded user password from O (Algorithm 7): undo the
  ## 19 XOR rounds, then the initial plain-key round from computeO.
  let key = md5raw(paddedPw(password))[0 ..< keyLen]
  if r == 2:
    return rc4s(key, o)
  result = o
  for i in countdown(19, 1):
    result = rc4s(rc4xor1(key, i), result)
  result = rc4s(key, result)

proc openCryptR26(enc: CosObj, idFirst, password: string,
    keyLen: int, r: int, encryptMeta: bool): PdfCrypt =
  let o = enc.dictGet("O")
  let u = enc.dictGet("U")
  if o.kind != coStr or o.sval.len != 32:
    pdfFail("bad /O in /Encrypt dictionary")
  if u.kind != coStr or u.sval.len != 32:
    pdfFail("bad /U in /Encrypt dictionary")
  let p = enc.dictGet("P").asInt()
  let fileKey = fileKeyR26(password, o.sval, p, idFirst, keyLen, r,
    encryptMeta)
  if userOk(fileKey, u.sval, idFirst, r):
    return PdfCrypt(present: true, r: r, keyLen: keyLen,
      fileKey: fileKey, stmCrypt: ccRC4, strCrypt: ccRC4,
      encryptMetadata: encryptMeta, encryptObjNum: -2)
  let asUser = ownerUserPw(o.sval, password, keyLen, r)
  let ownerKey = fileKeyR26(asUser, o.sval, p, idFirst, keyLen, r,
    encryptMeta)
  if userOk(ownerKey, u.sval, idFirst, r):
    return PdfCrypt(present: true, r: r, keyLen: keyLen,
      fileKey: ownerKey, stmCrypt: ccRC4,
      strCrypt: ccRC4, encryptMetadata: encryptMeta,
      encryptObjNum: -2)
  authFail(password)

proc openCryptR6(enc: CosObj, password: string): PdfCrypt =
  let o = enc.dictGet("O")
  let u = enc.dictGet("U")
  let oe = enc.dictGet("OE")
  let ue = enc.dictGet("UE")
  let perms = enc.dictGet("Perms")
  if o.kind != coStr or o.sval.len != 48:
    pdfFail("bad /O in /Encrypt dictionary (R6 needs 48 bytes)")
  if u.kind != coStr or u.sval.len != 48:
    pdfFail("bad /U in /Encrypt dictionary (R6 needs 48 bytes)")
  if oe.kind != coStr or oe.sval.len != 32:
    pdfFail("bad /OE in /Encrypt dictionary")
  if ue.kind != coStr or ue.sval.len != 32:
    pdfFail("bad /UE in /Encrypt dictionary")
  if perms.kind != coStr or perms.sval.len != 16:
    pdfFail("bad /Perms in /Encrypt dictionary")
  let pw = if password.len > 127: password[0 ..< 127] else: password
  var fileKey = ""
  # Owner first per the spec; the owner paths mix in the 48-byte U.
  if o.sval.len == 48 and u.sval.len == 48 and
      sha256raw(pw & o.sval[32 ..< 40] & u.sval) == o.sval[0 ..< 32]:
    fileKey = aesEcbDec(sha256raw(pw & o.sval[40 ..< 48] & u.sval),
      oe.sval)
  elif sha256raw(pw & u.sval[32 ..< 40]) == u.sval[0 ..< 32]:
    fileKey = aesEcbDec(sha256raw(pw & u.sval[40 ..< 48]), ue.sval)
  else:
    return authFail(password)
  let dec = aesEcbDec(fileKey, perms.sval)
  if dec[9 ..< 12] != "adb":
    pdfFail("bad /Perms in /Encrypt dictionary")
  let gotP = uint32(byte(dec[0])) or (uint32(byte(dec[1])) shl 8) or
    (uint32(byte(dec[2])) shl 16) or (uint32(byte(dec[3])) shl 24)
  if gotP != uint32(enc.dictGet("P").asInt() and 0xFFFFFFFF):
    pdfFail("/Perms do not match /P in /Encrypt dictionary")
  PdfCrypt(present: true, v: 5, r: 6, keyLen: 32, fileKey: fileKey,
    stmCrypt: ccAESV3, strCrypt: ccAESV3,
    encryptMetadata: dec[8] == 'T', encryptObjNum: -2)

proc cryptClassFor(cfm: string): CryptClass =
  case cfm
  of "None": ccNone
  of "V2": ccRC4
  of "AESV2": ccAESV2
  else: pdfFail("unsupported crypt filter /CFM /" & cfm &
      " (want None, V2 or AESV2)")

proc openCryptV4(enc: CosObj, idFirst, password: string,
    keyLen: int, encryptMeta: bool): PdfCrypt =
  var c = openCryptR26(enc, idFirst, password, keyLen, 4, encryptMeta)
  c.v = 4
  let cf = enc.dictGet("CF")
  if cf.kind != coDict:
    pdfFail("V4 /Encrypt needs a /CF dictionary")
  proc classOf(name: string): CryptClass =
    if name == "Identity":
      return ccNone
    let f = cf.dictGet(name)
    if f.kind != coDict:
      pdfFail("crypt filter /" & name & " missing from /CF")
    cryptClassFor(f.dictGet("CFM").asName())
  let stm = enc.dictGet("StmF")
  let strf = enc.dictGet("StrF")
  c.stmCrypt = if stm.kind == coNull or
      (stm.kind == coName and stm.name == "Identity"): ccNone
    else: classOf(stm.asName())
  c.strCrypt = if strf.kind == coNull or
      (strf.kind == coName and strf.name == "Identity"): ccNone
    else: classOf(strf.asName())
  c

proc openCrypt*(enc: CosObj, idFirst, password: string,
    encryptObjNum: int): PdfCrypt =
  ## Authenticate and derive keys from a resolved /Encrypt dict.
  ## Raises PdfError naming the problem (bad dict, wrong password,
  ## unsupported revision).
  if enc.kind != coDict:
    pdfFail("/Encrypt is not a dictionary")
  if enc.dictGet("Filter").asName() != "Standard":
    pdfFail("unsupported /Encrypt /Filter (want /Standard)")
  let v = enc.dictGet("V").asInt()
  let r = enc.dictGet("R").asInt()
  let meta = enc.dictGet("EncryptMetadata")
  let encryptMeta = meta.kind != coBool or meta.bval
  var c: PdfCrypt
  case v
  of 1:
    if r != 2:
      pdfFail("V1 /Encrypt needs /R 2, got " & $r)
    c = openCryptR26(enc, idFirst, password, 5, 2, true)
    c.v = 1
  of 2:
    if r != 2 and r != 3:
      pdfFail("V2 /Encrypt needs /R 2 or 3, got " & $r)
    let n = enc.dictGet("Length")
    let keyLen = if n.kind == coInt: n.ival div 8 else: 5
    if keyLen < 5 or keyLen > 16:
      pdfFail("bad /Encrypt /Length (want 40..128 bits)")
    c = openCryptR26(enc, idFirst, password, keyLen, r, true)
    c.v = 2
  of 4:
    if r != 4:
      pdfFail("V4 /Encrypt needs /R 4, got " & $r)
    let n = enc.dictGet("Length")
    let keyLen = if n.kind == coInt: n.ival div 8 else: 16
    if keyLen < 5 or keyLen > 16:
      pdfFail("bad /Encrypt /Length (want 40..128 bits)")
    c = openCryptV4(enc, idFirst, password, keyLen, encryptMeta)
  of 5:
    if r == 5:
      pdfFail("R5 encryption was retired; use R6 (V5) files")
    if r != 6:
      pdfFail("V5 /Encrypt needs /R 6, got " & $r)
    c = openCryptR6(enc, password)
  else:
    pdfFail("unsupported /Encrypt /V " & $v & " (want 1, 2, 4 or 5)")
  c.encryptObjNum = encryptObjNum
  c
