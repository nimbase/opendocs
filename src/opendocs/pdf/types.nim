## Shared types and errors for the PDF reader/writer.
##
## M1 scope: unencrypted files, classic xref tables, full COS value
## model including stream objects (raw bytes, no filter decoding yet).

type
  PdfError* = object of CatchableError

  PdfLimits* = object
    ## Caps applied before walking structure or allocating buffers.
    ## Violations raise PdfError.
    maxPages*: int
    maxScanBytes*: int ## header sniff window + startxref tail scan
    maxObjects*: int ## xref entries + registry cache size
    maxWalkDepth*: int ## page-tree nesting depth
    maxContentOps*: int ## operators per content stream
    maxImagePixels*: int ## width * height per image

  PageBox* = object
    index*: int
    width*: float64 ## MediaBox width in points
    height*: float64 ## MediaBox height in points

proc defaultPdfLimits*(): PdfLimits =
  PdfLimits(maxPages: 1000, maxScanBytes: 8192, maxObjects: 200000,
    maxWalkDepth: 32, maxContentOps: 100000, maxImagePixels: 100000000)

proc checkCount*(limits: PdfLimits, n: int, what: string) =
  if n < 0:
    raise newException(PdfError, "negative " & what & " count " & $n)
  if n > limits.maxObjects:
    raise newException(PdfError, what & " count " & $n &
      " exceeds limit " & $limits.maxObjects)
