## Custom locale format tests (P3-P5).
##
## Every `(code, value)` pair below was verified against excelize
## (`GetCellValue`) before freezing; `fmt_locale.xlsx` (built by
## `tests/gen_xlsx_numfmt_locale.nim`) covers the headline cases
## end to end. Locale data lives in `xlsx/locale_data.nim`
## (generated from the pinned excelize commit); `xlsx/locale.nim`
## holds the resolution mechanism (last-four-hex rule, tag scan,
## en-US aliases) and the Japanese/ROC era tables.
##
## Divergences from excelize, all header-documented:
## - No `CultureInfo` option: `ko-KR +2333` and the
##   `JA-JP-X-GANNEN` code-info table are unreachable; the `[$...]`
##   tag path is fully covered instead.
## - Border styles and fill patterns surface as raw OOXML names,
##   not excelize enum indexes (see `t_xlsx_style.nim`).

import std/[unittest, tables, strutils]
import opendocs/xlsx

const LocaleOracle = [
  ("[$-407]mmm d, yyyy", "44927", "Jan 1, 2023"),
  ("[$-407]mmmm d", "44927", "Januar 1"),
  ("[$-407]m", "44927", "1"),
  ("[$-40C]mmmm d", "44927", "janvier 1"),
  ("[$-411]mmm", "44927", "1月"),
  ("[$-411]mmmm", "44927", "1月"),
  ("[$-411]m", "44927", "1"),
  ("[$-411]dddd", "44927", "日曜日"),
  ("[$-411]ddd", "44927", "日"),
  ("[$-411]h:mm AM/PM", "44927.75", "6:00 午後"),
  ("[$-411]h:mm A/P", "44927.75", "6:00 午後"),
  ("[$-407]h:mm A/P", "44927.75", "6:00 PM"),
  ("[$-409]h:mm A/P", "44927.75", "6:00 PM"),
  ("[$-804]mmm", "44927", "1月"),
  ("[$-804]mmmm", "44927", "一月"),
  ("[$-804]m", "44927", "1"),
  ("[$-804]dddd", "44927", "星期日"),
  ("[$-404]mmm", "44927", "1月"),
  ("[$-404]mmmm", "44927", "1月"),
  ("[$-404]dddd", "44927", "星期日"),
  ("[$-404]ddd", "44927", "週日"),
  ("[$-419]mmm d", "44927", "янв. 1"),
  ("[$-419]mmmm", "44927", "январь"),
  ("[$-419]mmmmm", "44927", "я"),
  ("[$-419]ddd", "44927", "Вс"),
  ("[$-419]dddd", "44927", "воскресенье"),
  ("[$-411]ggge\"Y\"m\"M\"d\"D\"", "44927", "令和5Y1M1D"),
  ("[$-411]e/m/d", "44927", "5/1/1"),
  ("[$-411]ee", "44927", "05"),
  ("[$-411]e", "44927", "5"),
  ("[$-411]g", "44927", "R"),
  ("[$-411]gg", "44927", "令"),
  ("[$-411]ggg", "44927", "令和"),
  ("[$-404]e/m/d", "44927", "112/1/1"),
  ("[$-404]ee/m/d", "44927", "/1/1"),
  ("[$-404]e", "44927", "112"),
  ("[$-404]g", "44927", "民國"),
  ("[$-404]gg", "44927", "民國"),
  ("[$-404]ggge", "44927", "中華民國112"),
  ("[$-9999]m/d/yy", "44927", "44927"),
  ("[$-9999]0.00", "1.5", "1.50"),
  ("[$XYZ]m/d/yy", "44927", "XYZ1/1/23"),
  ("[$-407]A/P", "44927.75", "AM"),
  ("[$-40A]mmmm", "44927", "enero"),
  ("[$-40A]ddd", "44927", "do."),
  ("[$-816]mmmm", "44927", "janeiro"),
  ("[$-C07]mmmm", "44927", "Jänner"),
  ("[$-42D]ddd", "44927", "ig."),
  ("[$-42D]dddd", "44927", "igandea"),
  ("[$-42D]mmmm", "44927", "urtarrila"),
  ("[$-452]mmmm", "44927", "Ionawr"),
  ("[$-452]mmmmm", "44927", "I"),
  ("[$-404]A/P", "44927.75", "上午"),
  ("[$-404]h:mm AM/PM", "44927.75", "6:00 下午"),
  ("[$-411]mmmmm", "44927", "1"),
  ("[$-42A]mmmmm", "44927", "T 1"),
  ("[$-42A]mmm", "44927", "Thg 1"),
  ("[$USD]m/d/yy", "44927", "USD1/1/23"),
  ("[$€-42D]m/d/yy", "44927", "€1/1/23"),
  ("[$€-42D]mmmm", "44927", "€January"),
  ("[$USD-409]mmmm", "44927", "USDJanuary"),
  ("[$-409]m/d/yy", "44927", "1/1/23"),
  ("[$-F800]m/d/yy", "44927", "1/1/23"),
  ("[$USD]0.00", "1.5", "USD1.50"),
  ("[$-XYZ]0.00", "1.5", "1.50"),
  ("[$-404]0.00", "1.5", "1.50"),
  ("[$-409]0.00", "1.5", "1.50"),
  ("[$-407]d-mmm-yy", "1", "1-Jan-00"),
  ("[$-407]d-mmm-yy", "31", "31-Jan-00"),
  ("[$-407]d-mmm-yy", "32", "1-Feb-00"),
  ("[$-407]d-mmm-yy", "59", "28-Feb-00"),
  ("[$-407]d-mmm-yy", "60", "29-Feb-00"),
  ("[$-411]d-mmm-yy", "31", "31-1月-00"),
  ("[$-411]dddd", "1", "日曜日"),
  ("[$-3010429]mmmm d", "44927", "ژانويه 1"),
  ("[$-3010429]dddd", "44927", "يكشنبه"),
  ("[$-43E]mmmm d", "44927", "Januari 1"),
  ("[$-401]mmmm", "44927", "يناير"),
  ("[$-401]dddd", "44927", "الأحد"),
  ("[$-412]mmmm", "44927", "1월"),
  ("[$-412]mmm", "44927", "1"),
  ("[$-412]mmmmm", "44927", "1"),
  ("[$-413]mmmm", "44927", "januari"),
  ("[$-410]mmmm", "44927", "gennaio"),
  ("[$-406]mmmm", "44927", "januar"),
  ("[$-41D]mmmm d", "44927", "januari 1"),
  ("[$-41D]ddd", "44927", "sön"),
  ("[$-411]ggge", "4384", "1912"),
  ("[$-411]ggge", "100", "1900"),
  ("[$-411]e", "100", "1900"),
  ("[$-404]ggge", "4384", "中華民國元"),
  ("[$-404]e", "4384", "1"),
  ("[$-404]ggge", "100", "中華民國前12"),
  ("[$-404]e", "59", "12"),
  ("[$-411]dddd", "59", "火曜日"),
  ("[$-411]dddd", "60", "水曜日"),
  ("[$-407]dddd", "59", "Dienstag"),
  ("[$-409]dddd", "59", "Tuesday"),
  ("[$-409]ddd", "60", "Wed"),
  ("d-mmm-yy", "32", "1-Feb-00"),
  ("[$-409]d-mmm-yy", "32", "1-Feb-00"),
  ("[$-80A]mmmm", "44927", "enero"),
  ("[$-80A]ddd", "44927", "dom."),
  ("[$-464]mmmm", "44927", "Enero"),
  ("[$-464]mmmmm", "44927", "01"),
  ("[$-464]ddd", "44927", "Lin"),
  ("[$-42C]mmmm", "44927", "yanvar"),
  ("[$-42C]mmmmm", "44927", "y"),
  ("[$-41B]mmmm", "44927", "január"),
  ("[$-41B]ddd", "44927", "ne"),
  ("[$-425]mmmm", "44927", "jaanuar"),
  ("[$-425]ddd", "44927", "P"),
  ("[$-41F]mmmm", "44927", "Ocak"),
  ("[$-423]mmmm", "44927", "студзень"),
  ("[$-43F]mmmm", "44927", "Қаңтар"),
  ("[$-453]mmmmm", "44927", "ម"),
  ("[$-453]mmm", "44927", "១"),
  ("[$-453]mmmm", "44927", "មករា"),
  ("[$-63]mmm", "44927", "سلواغه"),
  ("[$-63]mmm", "45078", "چنګا ښ"),
  ("[$-63]mmmm", "45078", "چنګا ښزمرى"),
  ("[$-63]mmmmm", "45078", "چنګا ښزمرى"),

]

proc renderLoc(code, value: string): tuple[applied: bool, text: string] =
  var st = XlsxStylesheet(
    numFmts: {164: code}.toTable,
    cellXfs: @[XlsxXf(fontId: -1, fillId: -1, borderId: -1, xfId: -1),
      XlsxXf(numFmtId: 164, fontId: -1, fillId: -1, borderId: -1,
        xfId: -1)])
  let f = XlsxFile(styles: st)
  let info = f.formatInfo(value, ctyNumber, 1)
  (info.applied, info.text)

suite "locale renderer oracle":
  test "every oracle pair renders exactly":
    for (code, val, want) in LocaleOracle:
      let (applied, got) = renderLoc(code, val)
      check got == want
      # applied tracks transformation, not selection: raw-fallback
      # codes (unknown locales) legitimately report false.
      if not code.startsWith("[$-9999]") and not code.startsWith("[$XYZ]"):
        check applied

  test "unknown locales stay raw":
    check renderLoc("[$-XYZ]m/d/yy", "44927") == (false, "44927")
    check renderLoc("[$-9999]m/d/yy", "44927") == (false, "44927")
    check renderLoc("[$-XYZ]0.00", "1.5") == (true, "1.50")

suite "locale resolution":
  test "last-four-hex rule":
    # 3010429 fa-IR,301 becomes 0429 (load-bearing excelize rule).
    check renderLoc("[$-3010429]mmmm", "44927").text == "\u0698\u0627\u0646\u0648\u064A\u0647"
    let (found, loc) = resolveLocale("3010429")
    check found
    check "fa-IR" in loc.tags

  test "tags match case-insensitively":
    check renderLoc("[$-409]m/d/yy", "44927.5") ==
      renderLoc("[$-409]m/d/yy", "44927.5")
    let (found, loc) = resolveLocale("409")
    check found
    check "en-US" in loc.tags
    let (found2, loc2) = resolveLocale("de-de")
    check found2
    check "de-DE" in loc2.tags

  test "en-US aliases resolve":
    for tag in ["F800", "x-sysdate", "1010000", "F400", "x-systime"]:
      let (found, loc) = resolveLocale(tag)
      check found
      check "en-US" in loc.tags

  test "currency-only tags keep en-US names":
    check renderLoc("[$USD]m/d/yy", "44927") == (true, "USD1/1/23")

  test "currency plus language ignores the language":
    # excelize `currencyLanguageHandler` returns at the currency string.
    check renderLoc("[$\u20AC-42D]mmmm", "44927") == (true, "\u20ACJanuary")

  test "era years":
    # 4384 is 1912-01-01: Meiji-excluded in Japan, ROC year 1 in Taiwan.
    check renderLoc("[$-411]ggge", "4384") == (true, "1912")
    check renderLoc("[$-404]ggge", "4384") == (true, "\u4E2D\u83EF\u6C11\u570B\u5143")
    check renderLoc("[$-404]e", "4384") == (true, "1")
    check renderLoc("[$-411]ggge", "100") == (true, "1900")

suite "locale fixture end to end":
  const LocDir = "tests/fixtures/xlsx/"
  test "fixture cells render":
    let f = openXlsx(LocDir & "fmt_locale.xlsx")
    defer: f.closeXlsx()
    check f.getCellValue("Loc", "A1") == "Jan 1, 2023"
    check f.getCellValue("Loc", "A2") == "janvier 1"
    check f.getCellValue("Loc", "A3") == "\u65E5\u66DC\u65E5"
    check f.getCellValue("Loc", "A4") == "6:00 \u5348\u5F8C"
    check f.getCellValue("Loc", "A5") == "112/1/1"
    check f.getCellValue("Loc", "A6") == "\u044F\u043D\u0432\u0430\u0440\u044C"
    check f.getCellValue("Loc", "A7") == "\u0698\u0627\u0646\u0648\u064A\u0647"
    check f.getCellValue("Loc", "A8") == "\u20ACJanuary"
    check f.getCellValue("Loc", "A9") == "44927"
    check f.getCellValue("Loc", "A10") == "1912"
    check f.getCellValue("Loc", "A11") == "\u4E2D\u83EF\u6C11\u570B\u5143"
    check f.getCellValue("Loc", "A12") == "1-Feb-00"

  test "formatApplied tracks the fixture":
    let f = openXlsx(LocDir & "fmt_locale.xlsx")
    defer: f.closeXlsx()
    check f.formatApplied("Loc", "A1")
    check f.formatApplied("Loc", "A5")
    check not f.formatApplied("Loc", "A9")
