## Locale resolution and era data for custom date formats.
##
## Ports of excelize `getSupportedLanguageInfo` (`numfmt.go:5057`) with
## its load-bearing last-four-hex rule, plus the Japanese/ROC era tables
## (`japaneseEraYears/Names/Symbols`, `republicOfChinaYear/EraName`).
## Month/weekday/AM-PM strings come from `xlsx/locale_data` (generated
## from the pinned excelize commit); this file holds the mechanism.
##
## `ko-KR +2333` and `CultureInfo`-driven names are out of scope: the
## reader has no `CultureInfo` option, so only `[$...]` tags select
## locales (matching everything a reader can observe).

proc resolveLocale*(tag: string): tuple[found: bool, loc: XlsxLocale] =
  ## Match a `[$-...]` language tag to its locale (excelize
  ## `getSupportedLanguageInfo` order). `tag` is the raw `LanguageInfo`
  ## value (case-insensitive, like excelize):
  ## 1. en-US aliases (`F800`/`x-sysdate`/`1010000`/`F400`/`x-systime`,
  ##    which excelize rewrites to `409` before lookup),
  ## 2. last-four-hex LCID lookup (`3010429` fa-IR,301 becomes `0429`),
  ## 3. case-insensitive tag scan.
  ## Anything else reports not-found and the caller renders raw, like
  ## excelize's `ErrUnsupportedNumberFormat` path.
  let up = tag.toUpperAscii()
  if up in ["F800", "X-SYSDATE", "1010000", "F400", "X-SYSTIME"]:
    if XlsxLocaleById.hasKey(1033):
      return (true, XlsxLocaleById[1033])
    return (false, XlsxLocale())
  var hex = up
  if hex.len > 4: hex = hex[^4 .. ^1]
  if hex.len > 0:
    var isHex = true
    for ch in hex:
      if ch notin {'0' .. '9', 'A' .. 'F'}:
        isHex = false
        break
    if isHex:
      try:
        let id = parseHexInt(hex)
        if XlsxLocaleById.hasKey(id):
          return (true, XlsxLocaleById[id])
      except ValueError:
        discard
  for id, loc in XlsxLocaleById:
    for t in loc.tags:
      if t.toUpperAscii() == up:
        return (true, loc)
  (false, XlsxLocale())

const japaneseEraStarts = [(1868, 8, 8), (1912, 6, 30), (1926, 11, 25),
  (1989, 1, 8), (2019, 4, 1)]
  ## excelize `japaneseEraYears`, copied verbatim (day granularity;
  ## sub-day parts never distinguish).

const japaneseEraNames = ["\u660e\u6cbb", "\u5927\u6b63",
  "\u662d\u548c", "\u5e73\u6210", "\u4ee4\u548c"]
  ## excelize `japaneseEraNames` (full era names, oldest first).

const japaneseEraSymbols = ["M", "T", "S", "H", "R"]
  ## excelize `japaneseEraSymbols` (single-letter symbols).

func japaneseEraIndex(y, mo, d: int): int =
  ## Era index for a civil date, or -1 before Meiji (excelize `eraYear`
  ## parity: the loop excludes index 0, so Meiji dates report -1 too —
  ## callers emit nothing for `G` and the Gregorian year for `E`).
  for i in countdown(japaneseEraStarts.len - 1, 1):
    let (by, bm, bd) = japaneseEraStarts[i]
    if (y, mo, d) > (by, bm, bd):
      return i
  -1

const rocEpochYear = 1912
  ## excelize `republicOfChinaYear` (year part only; day granularity).

const rocEraNames = ["\u4e2d\u83ef\u6c11\u570b", "\u6c11\u570b",
  "\u524d"]
  ## excelize `republicOfChinaEraName` (full, short, pre-1912 suffix).
