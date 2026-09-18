## High-level PDF document API (M1: read unencrypted files).

import std/strutils
import ./types
import ./lexer
import ./cos
import ./docmodel

export types
export cos

type
  PdfDocument* = object
    version*: string
    pages*: seq[PageBox]
    hasEncrypt*: bool

proc pageCount*(d: PdfDocument): int {.inline.} = d.pages.len

proc readPdfBytes*(data: string, limits = defaultPdfLimits(),
    password = ""): PdfDocument =
  let head = data[0 ..< min(data.len, limits.maxScanBytes)]
  if find(head, "%PDF-") < 0:
    raise newException(PdfError,
      "not a PDF file (no %PDF- header in first " & $limits.maxScanBytes &
      " bytes)")
  var doc = openDoc(data, limits, password)
  let boxes = doc.pageBoxes()
  PdfDocument(version: parsePdfVersion(head), pages: boxes,
    hasEncrypt: doc.crypt.present)

proc readPdfBytes*(data: seq[byte],
    limits = defaultPdfLimits(), password = ""): PdfDocument =
  var s = newString(data.len)
  if data.len > 0:
    copyMem(addr s[0], unsafeAddr data[0], data.len)
  readPdfBytes(s, limits, password)

proc openPdf*(path: string, limits = defaultPdfLimits(),
    password = ""): PdfDocument =
  ## Snapshot of a file on disk. The file is memory-mapped, so even
  ## large documents parse with no heap copy; the mapping is released
  ## before return. For repeated lazy access use `openMappedDoc` and
  ## `close` it when done.
  var src = fromFile(path)
  defer: src.close()
  let head = src.slice(0, min(src.len, limits.maxScanBytes))
  if find(head, "%PDF-") < 0:
    raise newException(PdfError,
      "not a PDF file (no %PDF- header in first " & $limits.maxScanBytes &
      " bytes)")
  var doc = openDoc(src, limits, password)
  let boxes = doc.pageBoxes()
  PdfDocument(version: parsePdfVersion(head), pages: boxes,
    hasEncrypt: doc.crypt.present)

proc openPdfPassword*(data: string,
    limits = defaultPdfLimits()): bool =
  ## True when the newest trailer carries /Encrypt. Says nothing about
  ## whether the empty password suffices.
  parseXRef(data, limits).encrypt.kind != coNull

proc openPdfPasswordFile*(path: string,
    limits = defaultPdfLimits()): bool =
  ## `openPdfPassword` for a file on disk, via mmap.
  var src = fromFile(path)
  defer: src.close()
  parseXRef(src, limits).encrypt.kind != coNull
