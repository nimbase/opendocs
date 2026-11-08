# PDF Encryption

Module: `src/opendocs/pdf/crypt.nim`. Surfaced via `openDoc(..., password)`, `openPdf/readPdfBytes(..., password)`, `PdfDocument.hasEncrypt`.

```nim
import opendocs/pdf

echo openPdfPassword(readFile("enc.pdf")) # true if /Encrypt present
let doc = openPdf("enc.pdf", password = "user123")
echo doc.pageCount
```

- `CryptClass(ccNone/ccRC4/ccAESV2/ccAESV3)`, `PdfCrypt(present, v, r, keyLen, fileKey, stmCrypt/strCrypt, encryptMetadata, encryptObjNum)`, `cryptPad`.
- `aesCbcDec/aesEcbDec` (+ `aesCbcEnc/aesEcbEnc` fixtures), `decryptData(objNum, gen, data, cls)`, `decryptValue`, `computeO/computeU` (fixtures), `openCrypt(enc, idFirst, password, encryptObjNum)`.
- Supports `V1/R2`, `V2/R2-3` (RC4/MD5), `V4/R4` (`StmF/StrF`, `V2/AESV2/Identity`), `V5/R6` (SHA-256, AESV3, OE/UE/Perms). Rejects `R5`, non-`Standard`.
- `merge/write/forms/attach/sign` reject encrypted inputs.

See `tests/t_pdf_crypt.nim`.
