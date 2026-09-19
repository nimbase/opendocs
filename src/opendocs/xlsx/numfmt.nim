## Value formatting: eager stylesheet plus builtin number/date formats.
##
## Ports of the excelize `formattedValue` dispatch, `getCellDefault`
## precision trim, `timeFromExcelTime` (incl. the 1900 leap quirk and its
## renderer compensations), `floatToFraction`, and the observable behavior
## of the `nfp` format engine for every builtin format id. Custom format
## codes (`numFmts`) fall back to raw values until Phase C.

import std/[math, strutils]

const pow10tab = [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0,
  10000000.0, 100000000.0, 1000000000.0, 10000000000.0, 100000000000.0,
  1000000000000.0, 10000000000000.0, 100000000000000.0, 1000000000000000.0,
  10000000000000000.0, 100000000000000000.0, 1000000000000000000.0,
  10000000000000000000.0, 100000000000000000000.0, 1000000000000000000000.0,
  10000000000000000000000.0]
  ## Exact 10^n for n in 0..22 (all representable).

func pow10f(n: int): float =
  if n >= 0 and n < pow10tab.len: pow10tab[n]
  else: pow(10.0, n.float) # absurd widths: best effort only

# ---------------------------------------------------------- float helpers

func goModf(x: float): tuple[intp, fracp: float] =
  ## Go `math.Modf` (truncated integer part, same-sign fraction).
  let ip = trunc(x)
  (ip, x - ip)

func goParse(s: string): tuple[ok: bool, f: float] =
  try: (true, parseFloat(s))
  except ValueError: (false, 0.0)

func goFminus1(x: float): string =
  ## Shortest round-trip decimal expansion (Go `FormatFloat(f,'f',-1)`).
  ## Built from `$` (shortest digits) with manual exponent expansion.
  if x.classify in {fcInf, fcNegInf, fcNan}: return $x
  var s = $x
  var neg = false
  if s.startsWith("-"):
    neg = true
    s = s[1 .. ^1]
  var mant = s
  var exp = 0
  let ei = mant.find('e')
  if ei >= 0:
    try: exp = parseInt(mant[ei + 1 .. ^1])
    except ValueError: return $x
    mant = mant[0 ..< ei]
  var intD = mant
  var fracD = ""
  let di = mant.find('.')
  if di >= 0:
    intD = mant[0 ..< di]
    fracD = mant[di + 1 .. ^1]
  while fracD.len > 0 and fracD[^1] == '0':
    fracD.setLen(fracD.len - 1)
  var digits = intD & fracD
  var pointPos = intD.len + exp
  var li = 0
  while li < digits.len - 1 and digits[li] == '0':
    li += 1
  pointPos -= li
  digits = digits[li .. ^1]
  if digits == "": digits = "0"
  if pointPos <= 0:
    result = "0." & repeat('0', -pointPos) & digits
  elif pointPos >= digits.len:
    result = digits & repeat('0', pointPos - digits.len)
  else:
    result = digits[0 ..< pointPos] & "." & digits[pointPos .. ^1]
  if neg: result = "-" & result

func goG(x: float, prec: int): string =
  ## Significant-digits float format (Go `FormatFloat(x,'G',prec)`):
  ## `prec` significant digits, exponent form unless the decimal
  ## exponent lands in `[-4, prec)`, trailing zeros stripped.
  if x.classify in {fcInf, fcNegInf, fcNan}: return $x
  if x == 0.0: return "0"
  let ax = abs(x)
  var s = $ax
  # shortest digits + decimal exponent via goFminus1 parts
  var f = goFminus1(ax)
  var neg = false
  if f.startsWith("-"):
    neg = true
    f = f[1 .. ^1]
  var digits: string
  var pointPos: int
  let di = f.find('.')
  if di < 0:
    digits = f
    pointPos = f.len
  else:
    digits = f[0 ..< di] & f[di + 1 .. ^1]
    pointPos = di
  var li = 0
  while li < digits.len - 1 and digits[li] == '0':
    li += 1
  pointPos -= li
  digits = digits[li .. ^1]
  # round to prec significant digits (half away from zero)
  if digits.len > prec:
    var d = digits[0 ..< prec]
    if digits[prec] >= '5':
      var i = prec - 1
      var carry = true
      while carry and i >= 0:
        if d[i] == '9':
          d[i] = '0'
          i -= 1
        else:
          d[i] = char(d[i].ord + 1)
          carry = false
      if carry:
        d = "1" & repeat('0', prec - 1)
        pointPos += 1
    digits = d
  while digits.len > 1 and digits[^1] == '0':
    digits.setLen(digits.len - 1)
  let exp10 = pointPos - 1
  if exp10 >= -4 and exp10 < prec:
    if pointPos <= 0:
      result = "0." & repeat('0', -pointPos) & digits
    elif pointPos >= digits.len:
      result = digits & repeat('0', pointPos - digits.len)
    else:
      result = digits[0 ..< pointPos] & "." & digits[pointPos .. ^1]
  else:
    result = $digits[0]
    if digits.len > 1: result &= "." & digits[1 .. ^1]
    result &= "E" & (if exp10 < 0: "-" else: "+") &
      align($abs(exp10), 2, '0')
  if neg: result = "-" & result

func isNumericV(s: string): tuple[isNum: bool, prec: int, num: float] =
  ## Port of excelize `isNumeric`: precision counts digits of the
  ## shortest decimal expansion, point excluded.
  if "_" in s: return (false, 0, 0.0)
  let (ok, f) = goParse(s)
  if not ok: return (false, 0, 0.0)
  let plain = goFminus1(f)
  (true, plain.len - (if "." in plain: 1 else: 0), f)

func withinPrecision(s: string): bool =
  ## Port of excelize `isNumWithinPrecision` (Excel 15-digit rule).
  if "." in s or "e" in s or "E" in s: return false
  var t = s
  while t.len > 0 and t[0] in {'+', '-', '0'}: t = t[1 .. ^1]
  while t.len > 0 and t[^1] == '0': t.setLen(t.len - 1)
  t.len <= 15

func generalTrim(v: string): string =
  ## Port of excelize `getCellDefault` (non-raw branch): 15-digit trim.
  let (isNum, prec, num) = isNumericV(v)
  if not isNum: return v
  if prec > 15 and not withinPrecision(v): goG(num, 15)
  else: goFminus1(num)

# ------------------------------------------------------------ civil dates

func daysFromCivil(y, m, d: int): int =
  ## Howard Hinnant's days-from-civil (proleptic Gregorian). All inputs
  ## here are non-negative, so `div` truncation equals flooring.
  var yy = y
  if m <= 2: yy -= 1
  let era = yy div 400
  let yoe = yy - era * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

func civilFromDays(z: int): tuple[y, m, d: int] =
  ## Inverse of daysFromCivil (non-negative inputs only).
  let zz = z + 719468
  let era = zz div 146097
  let doe = zz - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  if m <= 2: y += 1
  (y, m, d)

func fliegelVanFlandern(jd: int): tuple[y, m, d: int] =
  ## Exact port of excelize `doTheFliegelAndVanFlandernAlgorithm`.
  let l0 = jd + 68569
  let n = (4 * l0) div 146097
  var l = l0 - (146097 * n + 3) div 4
  let i = (4000 * (l + 1)) div 1461001
  l = l - (1461 * i) div 4 + 31
  let j = (80 * l) div 2447
  let d = l - (2447 * j) div 80
  let l2 = j div 11
  (100 * (n - 49) + i + l2, j + 2 - 12 * l2, d)

func fractionOfADay(fraction: float): tuple[h, mi, s: int, ns: int64] =
  ## Exact port of excelize `fractionOfADay` (rounds to microseconds).
  var fr = int64(86400.0 * 1e9 * fraction + 500.0)
  let ns = (fr mod 1000000000) div 1000 * 1000
  fr = fr div 1000000000
  let s = fr mod 60
  fr = fr div 60
  (int(fr div 60), int(fr mod 60), int(s), ns)

type RawCivil = tuple[y, mo, d, h, mi, s: int, ns: int64]

func julianParts(serial: float, date1904: bool): tuple[y, mo, d: int,
    fr: float] =
  ## Civil date plus day fraction for serials on the Julian path
  ## (`whole <= 61`, 1900 system). Exact port of the
  ## `julianDateToGregorianTime` call in `timeFromExcelTime`.
  let off = if date1904: 16480.0 else: 15018.0
  let (p2i, p2f) = goModf(serial + off)
  var days = 2400000.0 + p2i # MJD0 integer part
  var fr = 0.5 + p2f
  if -0.5 < fr and fr < 0.5:
    fr += 0.5
  elif fr >= 0.5:
    days += 1.0
    fr -= 0.5
  elif fr <= -0.5:
    days -= 1.0
    fr += 1.5
  let c = fliegelVanFlandern(int(days))
  (c.y, c.m, c.d, fr)

func serialToCivil(serial: float, date1904: bool): RawCivil =
  ## Exact port of excelize `timeFromExcelTime` (caller guarantees
  ## `serial >= 0`; negatives fall back to raw upstream). The epoch
  ## branch rounds sub-second remainders over 500ms up a second; the
  ## Julian branch keeps microsecond precision.
  let whole = int64(floor(serial))
  let frac = serial - whole.float
  if not date1904 and whole <= 61:
    let (y, mo, d, fr) = julianParts(serial, date1904)
    let (h, mi, s, ns) = fractionOfADay(fr)
    return (y, mo, d, h, mi, s, ns)
  let epochDays =
    if date1904: daysFromCivil(1904, 1, 1)
    else: daysFromCivil(1899, 12, 30)
  let nsTotal = int64(86400e9 * (frac + 1e-9))
  var daySecs = nsTotal div 1000000000
  var nsRem = nsTotal mod 1000000000
  if nsRem div 1000000 > 500:
    daySecs += 1
    nsRem = 0
  let totalDays = whole + daySecs div 86400
  daySecs = daySecs mod 86400
  let (y, mo, d) = civilFromDays(epochDays + int(totalDays))
  (y, mo, d, int(daySecs div 3600), int((daySecs div 60) mod 60),
    int(daySecs mod 60), nsRem)

func isoToSerial(v: string): tuple[ok: bool, serial: string] =
  ## Port of excelize `getCellDate` (non-raw branch): ISO 8601 `t="d"`
  ## values become serial strings (`FormatFloat 'G' 15`).
  var dt = (y: 0, mo: 0, d: 0, h: 0, mi: 0, s: 0)
  var frac = 0.0
  var matched = false
  try:
    let w = v.replace(",", ".")
    if w.endsWith("Z"):
      let b = w[0 .. ^2]
      if "-" in b and "T" in b:
        let p = b.split('T')
        let dp = p[0].split('-')
        let tp = p[1].split(':')
        if dp.len == 3 and tp.len == 3:
          dt = (parseInt(dp[0]), parseInt(dp[1]), parseInt(dp[2]),
            parseInt(tp[0]), parseInt(tp[1]), parseInt(tp[2]))
          matched = true
      elif "T" in b:
        let p = b.split('T')
        if p[0].len == 8 and p[1].len >= 6:
          dt = (parseInt(p[0][0 .. 3]), parseInt(p[0][4 .. 5]),
            parseInt(p[0][6 .. 7]), parseInt(p[1][0 .. 1]),
            parseInt(p[1][2 .. 3]), parseInt(p[1][4 .. 5]))
          matched = true
    elif "-" in w and " " in w:
      let p = w.split(' ')
      let dp = p[0].split('-')
      let tp = p[1].split(':')
      if dp.len == 3 and tp.len == 3:
        dt = (parseInt(dp[0]), parseInt(dp[1]), parseInt(dp[2]),
          parseInt(tp[0]), parseInt(tp[1]), parseInt(tp[2]))
        matched = true
    else:
      let p = w.split('T')
      if p.len == 2 and p[0].len == 8 and p[1].len >= 6:
        var sec = p[1][4 .. 5]
        if "." in p[1]:
          let sp = p[1].split('.')
          if sp[0].len >= 6:
            sec = sp[0][4 .. 5]
            frac = parseFloat("0." & sp[1])
        dt = (parseInt(p[0][0 .. 3]), parseInt(p[0][4 .. 5]),
          parseInt(p[0][6 .. 7]), parseInt(p[1][0 .. 1]),
          parseInt(p[1][2 .. 3]), parseInt(sec))
        matched = true
  except ValueError, IndexDefect:
    return (false, v)
  if not matched: return (false, v)
  # excelize `timeToExcelTime`: days since 1899-12-31, plus the Lotus
  # leap day for dates past 1900-02-28 (1900 system only here).
  let days = (daysFromCivil(dt.y, dt.mo, dt.d) -
    daysFromCivil(1899, 12, 31)).float
  var serial = days + (dt.h.float * 3600.0 + dt.mi.float * 60.0 +
    dt.s.float) / 86400.0 + frac / 86400.0
  if dt.y > 1900 or (dt.y == 1900 and (dt.mo > 2 or
      (dt.mo == 2 and dt.d > 28))):
    serial += 1.0
  (true, goG(serial, 15))

# --------------------------------------------------- builtin format codes

func builtinFmtCode(id: int): string =
  ## en-US builtin codes (excelize `builtInNumFmt`). "" selects the raw
  ## fallback: locale ids, gaps, customs (Phase C), and the id-48 quirk
  ## (`##0.0E+0` passes through unformatted in excelize).
  case id
  of 0: "general"
  of 1: "0"
  of 2: "0.00"
  of 3: "#,##0"
  of 4: "#,##0.00"
  of 9: "0%"
  of 10: "0.00%"
  of 11: "0.00E+00"
  of 12: "# ?/?"
  of 13: "# ??/??"
  of 14: "mm-dd-yy"
  of 15: "d-mmm-yy"
  of 16: "d-mmm"
  of 17: "mmm-yy"
  of 18: "h:mm AM/PM"
  of 19: "h:mm:ss AM/PM"
  of 20: "hh:mm"
  of 21: "hh:mm:ss"
  of 22: "m/d/yy hh:mm"
  of 37: "#,##0 ;(#,##0)"
  of 38: "#,##0 ;[red](#,##0)"
  of 39: "#,##0.00 ;(#,##0.00)"
  of 40: "#,##0.00 ;[red](#,##0.00)"
  of 41: "_(* #,##0_);_(* \\(#,##0\\);_(* \"-\"_);_(@_)"
  of 42: "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)"
  of 43: "_(* #,##0.00_);_(* \\(#,##0.00\\);_(* \"-\"??_);_(@_)"
  of 44: "_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)"
  of 45: "mm:ss"
  of 46: "[h]:mm:ss"
  of 47: "mm:ss.0"
  of 49: "@"
  else: ""

# ------------------------------------------------------- number rendering

func commafyInt(s: string): string =
  ## Thousands separators on a plain integer string (sign handled by
  ## the caller; excelize `printCommaSep` parity).
  var neg = false
  var digits = s
  if digits.startsWith("-"):
    neg = true
    digits = digits[1 .. ^1]
  elif digits.startsWith("+"):
    digits = digits[1 .. ^1]
  var res = ""
  for i, ch in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: res &= ","
    res &= ch
  if neg: "-" & res else: res

func renderFixed(absVal: float, decimals: int, thousands: bool): string =
  ## Fixed-point rendering on the float (excelize `numberHandler`
  ## `Sprintf` path): half-away rounding at `decimals`, optional
  ## thousands separators.
  let ratio = pow10f(decimals)
  let num = round(absVal * ratio) / ratio
  var s = formatFloat(num, ffDecimal, decimals)
  if decimals == 0 and s.endsWith("."): s.setLen(s.len - 1)
  if thousands:
    let di = s.find('.')
    if di < 0: return commafyInt(s)
    return commafyInt(s[0 ..< di]) & s[di .. ^1]
  s

func renderBig(absVal: float, decimals: int, thousands: bool,
    percent: bool): string =
  ## Over-15-digit path (excelize `printBigNumber`): shortest decimal
  ## expansion, thousands separators, fraction zero-pad or truncate
  ## (never round), percent suffix.
  var res = goFminus1(absVal)
  if thousands:
    let di = res.find('.')
    if di < 0: res = commafyInt(res)
    else: res = commafyInt(res[0 ..< di]) & res[di .. ^1]
  if decimals > 0:
    let di = res.find('.')
    if di >= 0:
      let have = res.len - di - 1
      if have < decimals: res &= repeat('0', decimals - have)
      elif have > decimals: res = res[0 ..< di + 1 + decimals]
    else:
      res &= "." & repeat('0', decimals)
  if percent: res &= "%"
  res

func renderNumberAbs(absVal: float, decimals: int, thousands: bool,
    percent: bool): string =
  ## Fixed/percent core with the big-number branch. `absVal` is the
  ## non-negative magnitude; the caller adds signs and suffixes.
  let dec = goFminus1(absVal)
  let di = dec.find('.')
  let intD = if di < 0: dec else: dec[0 ..< di]
  let prec = dec.len - (if di < 0: 0 else: 1)
  if intD.len + decimals > 15 and prec > 15:
    return renderBig(absVal, decimals, thousands, percent)
  var res = renderFixed(absVal, decimals, thousands)
  if percent: res &= "%"
  res

func renderScientific(absVal: float, decimals: int): string =
  ## `0.00E+00` shape (excelize `%.NE` branch): normalized mantissa,
  ## uppercase E, exponent padded to two digits minimum.
  var s = formatFloat(absVal, ffScientific, decimals)
  let ei = s.find('e')
  if ei < 0: return s
  var exp = s[ei + 1 .. ^1]
  var sign = "+"
  if exp.startsWith("-"):
    sign = "-"
    exp = exp[1 .. ^1]
  elif exp.startsWith("+"):
    exp = exp[1 .. ^1]
  while exp.len > 1 and exp[0] == '0': exp = exp[1 .. ^1]
  s[0 ..< ei] & "E" & sign & align(exp, 2, '0')

func continuedFraction(r0: float, limit: int64): tuple[num, den: int64] =
  ## Exact port of excelize `floatToFracUseContinuedFraction`.
  var p1: int64 = 1
  var q1: int64 = 0
  var p2: int64 = 0
  var q2: int64 = 1
  var lasta: int64 = 0
  var lastb: int64 = 0
  var r = r0
  while true:
    let a = int64(floor(r))
    let curra = a * p1 + p2
    let currb = a * q1 + q2
    p2 = p1
    q2 = q1
    p1 = curra
    q1 = currb
    let frac = r - a.float
    if q1 >= limit: return (lasta, lastb)
    if abs(frac) < 1e-12: return (curra, currb)
    lasta = curra
    lastb = currb
    r = 1.0 / frac

func renderFraction(absVal: float, numW, denW: int): string =
  ## `# ?/?` shapes (excelize `floatToFraction`): truncated integer
  ## part, space, numerator right-aligned to `numW`, `/`, denominator
  ## left-aligned (space-padded) to `denW`.
  let intP = $int64(floor(absVal))
  let (_, frac) = goModf(absVal)
  let (num, den) = continuedFraction(frac, int64(pow10f(denW)))
  var fracStr: string
  if num == 0:
    fracStr = repeat(' ', numW + denW + 1)
  else:
    let ns = $num
    let ds = $den
    fracStr = repeat(' ', max(numW - ns.len, 0)) & ns & "/" & ds &
      repeat(' ', max(denW - ds.len, 0))
  intP & " " & fracStr

# --------------------------------------------------------- date rendering

const monthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
  "Sep", "Oct", "Nov", "Dec"]
const monthFull = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"]
const weekdayAbbr = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const weekdayFull = ["Sunday", "Monday", "Tuesday", "Wednesday",
  "Thursday", "Friday", "Saturday"]

type
  DateTokKind = enum
    dtkYear, dtkMonth, dtkDay, dtkHour, dtkMinute, dtkSecond, dtkMs,
    dtkAmPm, dtkElapsedH, dtkElapsedM, dtkElapsedS, dtkLit
  DateTok = tuple[kind: DateTokKind, width: int, text: string]

func tokenizeDateCode(code: string): seq[DateTok] =
  ## Minimal tokenizer for the builtin date/time codes: runs of
  ## y/m/d/h/s (case-insensitive), `[h]`/`[m]`/`[s]` elapsed, AM/PM
  ## markers, `[$...]` locale tags (dropped), quoted/escaped literals.
  var i = 0
  while i < code.len:
    let ch = code[i]
    if ch == '[':
      let j = code.find(']', i)
      if j > i:
        let inner = code[i + 1 ..< j].toUpperAscii()
        if inner == "H": result.add (dtkElapsedH, 0, "")
        elif inner == "M": result.add (dtkElapsedM, 0, "")
        elif inner == "S": result.add (dtkElapsedS, 0, "")
        i = j + 1
        continue
      result.add (dtkLit, 0, $ch)
      i += 1
    elif ch == '$' and i + 1 < code.len and code[i + 1] == '-':
      let j = code.find(']', i) # [$...] locale tag: drop
      i = if j > i: j + 1 else: i + 2
    elif ch == '"':
      let j = code.find('"', i + 1)
      if j > i:
        result.add (dtkLit, 0, code[i + 1 ..< j])
        i = j + 1
      else:
        result.add (dtkLit, 0, $ch)
        i += 1
    elif ch == '\\' and i + 1 < code.len:
      result.add (dtkLit, 0, $code[i + 1])
      i += 2
    elif ch in {'y', 'Y'}:
      var n = 0
      while i < code.len and code[i] in {'y', 'Y'}: n += 1; i += 1
      result.add (dtkYear, n, "")
    elif ch in {'m', 'M'}:
      var n = 0
      while i < code.len and code[i] in {'m', 'M'}: n += 1; i += 1
      result.add (dtkMonth, n, "")
    elif ch in {'d', 'D'}:
      var n = 0
      while i < code.len and code[i] in {'d', 'D'}: n += 1; i += 1
      result.add (dtkDay, n, "")
    elif ch in {'h', 'H'}:
      var n = 0
      while i < code.len and code[i] in {'h', 'H'}: n += 1; i += 1
      result.add (dtkHour, n, "")
    elif ch in {'s', 'S'}:
      var n = 0
      while i < code.len and code[i] in {'s', 'S'}: n += 1; i += 1
      var ms = 0
      if i < code.len and code[i] == '.':
        var j = i + 1
        while j < code.len and code[j] == '0' and ms < 3:
          ms += 1
          j += 1
        if ms > 0: i = j
      result.add (dtkSecond, n, "")
      if ms > 0:
        result.add (dtkLit, 0, ".")
        result.add (dtkMs, ms, "")
    elif code[i .. ^1].toUpperAscii().startsWith("AM/PM"):
      result.add (dtkAmPm, 0, code[i .. i + 4])
      i += 5
    elif code[i .. ^1].toUpperAscii().startsWith("A/P"):
      result.add (dtkAmPm, 0, code[i .. i + 2])
      i += 3
    else:
      result.add (dtkLit, 0, $ch)
      i += 1
  # Month/minute disambiguation (excelize `isMonthToken`): an `m`
  # token is minutes when an h/s datetime token precedes it or an
  # `s` datetime token follows it (elapsed tokens count as time).
  for k, t in result:
    if t.kind != dtkMonth: continue
    var timePrev = false
    var secondsNext = false
    for j in countdown(k - 1, 0):
      if result[j].kind in {dtkHour, dtkSecond, dtkElapsedH, dtkElapsedM,
          dtkElapsedS}:
        timePrev = true
        break
      if result[j].kind in {dtkYear, dtkMonth, dtkDay, dtkMinute}:
        break
    for j in k + 1 ..< result.len:
      if result[j].kind == dtkSecond:
        secondsNext = true
        break
      if result[j].kind in {dtkYear, dtkMonth, dtkDay, dtkHour, dtkMinute}:
        break
    if timePrev or secondsNext:
      result[k] = (dtkMinute, t.width, t.text)

type DateParts = tuple[yr, moNum: int, moAbbr, moFull: string, d, h,
  mi, s: int, msDigit: string, ap: string, elH, elM, elS: int,
  weekday: int] ## weekday: 0=Sunday (Go `time.Weekday` parity)

func dateParts(serial: float, date1904: bool,
    wantMs: bool): tuple[ok: bool, dp: DateParts] =
  ## Civil parts plus excelize renderer compensations: month numbers
  ## clamp below 2 and at the fake 1900-02-29; years clamp below 2;
  ## days use the lag-corrected serial; month NAMES use the corrected
  ## serial (`localMonthsName` parity).
  if serial < 0.0:
    return (false, (yr: 0, moNum: 0, moAbbr: "", moFull: "", d: 0, h: 0,
      mi: 0, s: 0, msDigit: "", ap: "", elH: 0, elM: 0, elS: 0, weekday: 0))
  var t = serialToCivil(serial, date1904)
  if not wantMs and t.ns >= 500000000:
    # dateTimeHandler second rounding (skipped for ms formats)
    var secs = t.h * 3600 + t.mi * 60 + t.s + 1
    var extraDays = 0
    if secs >= 86400:
      secs -= 86400
      extraDays = 1
    let base = if date1904: daysFromCivil(1904, 1, 1)
      else: daysFromCivil(1899, 12, 30)
    let c = civilFromDays(daysFromCivil(t.y, t.mo, t.d) - base +
      extraDays + base)
    t = (c.y, c.m, c.d, secs div 3600, (secs div 60) mod 60, secs mod 60, 0)
  var moNum = t.mo
  if serial < 2.0: moNum = 1
  if serial >= 60.0 and serial < 61.0: moNum = 2
  var yr = t.y
  if serial < 2.0: yr = 1900
  var day = t.d
  if serial < 1.0: day = 0
  elif serial >= 1.0 and serial < 60.0:
    day = serialToCivil(serial + 1.0, date1904).d
  elif serial >= 60.0 and serial < 61.0:
    day = 29
  var nc = t
  if serial < 1.0: nc = serialToCivil(serial + 2.0, date1904)
  elif serial >= 1.0 and serial < 60.0:
    nc = serialToCivil(serial + 1.0, date1904)
  var msDigit = ""
  if wantMs:
    msDigit = align($(t.ns div 1000000), 3, '0')
  let ap = if t.h >= 12: "PM" else: "AM"
  # elapsed since the 1900 epoch (excelize always uses it, even for
  # 1904 workbooks)
  let e1900 = daysFromCivil(1899, 12, 30)
  let daysF = (daysFromCivil(t.y, t.mo, t.d) - e1900).float +
    (t.h.float * 3600.0 + t.mi.float * 60.0 + t.s.float +
      t.ns.float / 1e9) / 86400.0
  # Sakamoto weekday of the (possibly lagged) civil date, 0=Sunday
  let mAdj = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4][t.mo - 1]
  let yy = if t.mo < 3: t.y - 1 else: t.y
  let weekday = (yy + yy div 4 - yy div 100 + yy div 400 + mAdj +
    t.d) mod 7
  (true, (yr, moNum, monthAbbr[nc.mo - 1], monthFull[nc.mo - 1], day,
    t.h, t.mi, t.s, msDigit, ap, int(floor(daysF * 24.0)),
    int(floor(daysF * 1440.0)), int(floor(daysF * 86400.0)), weekday))

proc renderDateCode(code: string, serial: float,
    date1904: bool): tuple[ok: bool, text: string] =
  ## Render a builtin date/time code. `ok=false` selects raw fallback.
  let toks = tokenizeDateCode(code)
  var wantMs = false
  var hasAp = false
  for t in toks:
    if t.kind == dtkMs: wantMs = true
    if t.kind == dtkAmPm: hasAp = true
  let (ok, dp) = dateParts(serial, date1904, wantMs)
  if not ok: return (false, "")
  var res = ""
  for t in toks:
    case t.kind
    of dtkYear:
      if t.width <= 2: res &= align($(dp.yr mod 100), 2, '0')
      else: res &= $dp.yr
    of dtkMonth:
      if t.width == 1: res &= $dp.moNum
      elif t.width == 2: res &= align($dp.moNum, 2, '0')
      elif t.width == 3: res &= dp.moAbbr
      elif t.width == 4: res &= dp.moFull
      else: res &= dp.moAbbr[0 .. 0]
    of dtkDay:
      if t.width == 1: res &= $dp.d
      elif t.width == 2: res &= align($dp.d, 2, '0')
      elif t.width == 3: res &= weekdayAbbr[dp.weekday]
      else: res &= weekdayFull[dp.weekday]
    of dtkHour:
      var h = dp.h
      if hasAp:
        h = h mod 12
        if h == 0: h = 12
      if t.width == 1: res &= $h
      else: res &= align($h, 2, '0')
    of dtkMinute:
      if t.width == 1: res &= $dp.mi
      else: res &= align($dp.mi, 2, '0')
    of dtkSecond:
      if t.width == 1: res &= $dp.s
      else: res &= align($dp.s, 2, '0')
    of dtkMs:
      res &= dp.msDigit[0 ..< min(t.width, dp.msDigit.len)]
    of dtkAmPm:
      let upper = t.text == t.text.toUpperAscii()
      var ap = dp.ap
      if not upper: ap = ap.toLowerAscii()
      if t.text.len <= 3: ap = ap[0 .. 0]
      res &= ap
    of dtkElapsedH: res &= $dp.elH
    of dtkElapsedM: res &= $dp.elM
    of dtkElapsedS: res &= $dp.elS
    of dtkLit: res &= t.text
  (true, res)

# ------------------------------------------------- sections + accounting

func splitSections(code: string): seq[string] =
  ## Top-level `;` split honoring quotes, escapes, and `[...]` groups.
  var cur = ""
  var i = 0
  while i < code.len:
    let ch = code[i]
    if ch == '"':
      let j = code.find('"', i + 1)
      if j > i:
        cur &= code[i .. j]
        i = j + 1
      else:
        cur &= ch
        i += 1
    elif ch == '\\' and i + 1 < code.len:
      cur &= code[i .. i + 1]
      i += 2
    elif ch == '[':
      let j = code.find(']', i)
      if j > i:
        cur &= code[i .. j]
        i = j + 1
      else:
        cur &= ch
        i += 1
    elif ch == ';':
      result.add cur
      cur = ""
      i += 1
    else:
      cur &= ch
      i += 1
  result.add cur

func renderSectionNumber(absVal: float, sec: string): string =
  ## One accounting-style section: alignment `_x` -> space, fill `*x`
  ## dropped, `\x` escapes, quoted literals, `[color]` dropped, one
  ## number cluster rendered fixed-point with thousands separators.
  var decimals = 0
  var thousands = false
  var seenPoint = false
  for ch in sec:
    if ch == '.': seenPoint = true
    elif ch == ',' and not seenPoint: thousands = true
    elif ch == '0' and seenPoint: decimals += 1
  var res = ""
  var numDone = false
  var i = 0
  while i < sec.len:
    let ch = sec[i]
    if ch == '_' and i + 1 < sec.len:
      res &= " "
      i += 2
    elif ch == '*' and i + 1 < sec.len:
      i += 2
    elif ch == '\\' and i + 1 < sec.len:
      res &= sec[i + 1]
      i += 2
    elif ch == '"':
      let j = sec.find('"', i + 1)
      if j > i:
        res &= sec[i + 1 ..< j]
        i = j + 1
      else: i += 1
    elif ch == '[':
      let j = sec.find(']', i)
      i = if j > i: j + 1 else: i + 1
    elif ch in {'0', '#', '?', '.', ','} and not numDone:
      res &= renderNumberAbs(absVal, decimals, thousands, false)
      numDone = true
      i += 1
    elif ch in {'0', '#', '?', '.', ','}:
      i += 1 # cluster continuation already rendered
    else:
      res &= ch
      i += 1
  res

func renderSectionText(value, sec: string): string =
  ## Text section (excelize `textHandler` + alignment): only `@`/`0`
  ## placeholders (the value), quoted/escaped literals, and a single
  ## space per leading/trailing alignment marker are emitted; every
  ## other bare character (parens, spaces, ...) is dropped.
  var body = sec
  var padStart = false
  var padEnd = false
  if body.len > 1 and body[0] == '_':
    padStart = true
    body = body[2 .. ^1]
  if body.len > 1 and body[^2] == '_':
    padEnd = true
    body = body[0 .. ^3] & body[^1 .. ^1]
  var res = ""
  var i = 0
  while i < body.len:
    let ch = body[i]
    if ch == '_' and i + 1 < body.len:
      i += 2
    elif ch == '*' and i + 1 < body.len:
      i += 2
    elif ch == '\\' and i + 1 < body.len:
      res &= body[i + 1]
      i += 2
    elif ch == '"':
      let j = body.find('"', i + 1)
      if j > i:
        res &= body[i + 1 ..< j]
        i = j + 1
      else: i += 1
    elif ch == '[':
      let j = body.find(']', i)
      i = if j > i: j + 1 else: i + 1
    elif ch == '@' or ch == '0':
      res &= value
      i += 1
    else:
      i += 1 # bare chars dropped in text sections
  (if padStart: " " else: "") & res & (if padEnd: " " else: "")

# ------------------------------------------------------------- dispatch

proc formatBuiltin(value: string, numFmtId: int, cellType: CellType,
    date1904: bool): tuple[ok: bool, text: string] =
  ## Render under a builtin id. `ok=false` selects the raw fallback
  ## (unknown ids, customs handled upstream, id-48 quirk, non-numeric
  ## values under number/date codes).
  let code = builtinFmtCode(numFmtId)
  if code == "": return (false, value)
  if code == "general" or code == "@": return (true, value)
  if cellType != ctyNumber and cellType != ctyDate:
    # text section: only 4-section codes have one; otherwise raw
    let secs = splitSections(code)
    if secs.len > 3: return (true, renderSectionText(value, secs[3]))
    return (true, value)
  if numFmtId in {12, 13}:
    let (ok, f) = goParse(value)
    if not ok: return (false, value)
    let w = if numFmtId == 12: 1 else: 2
    var s = renderFraction(abs(f), w, w)
    if f < 0.0: s = "-" & s
    return (true, s)
  if numFmtId in {14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47}:
    let (ok, f) = goParse(value)
    if not ok: return (false, value)
    return renderDateCode(code, f, date1904)
  if numFmtId in {37, 38, 39, 40, 41, 42, 43, 44}:
    let (ok, f) = goParse(value)
    if not ok: return (false, value)
    let secs = splitSections(code)
    if f >= 0.0:
      return (true, renderSectionNumber(abs(f), secs[0]))
    if secs.len > 1:
      return (true, renderSectionNumber(abs(f), secs[1]))
    return (true, "-" & renderSectionNumber(abs(f), secs[0]))
  # fixed / percent / scientific
  let (ok, f) = goParse(value)
  if not ok: return (false, value)
  let a = abs(f)
  var s: string
  case numFmtId
  of 1: s = renderNumberAbs(a, 0, false, false)
  of 2: s = renderNumberAbs(a, 2, false, false)
  of 3: s = renderNumberAbs(a, 0, true, false)
  of 4: s = renderNumberAbs(a, 2, true, false)
  of 9: s = renderNumberAbs(a * 100.0, 0, false, true)
  of 10: s = renderNumberAbs(a * 100.0, 2, false, true)
  of 11: s = renderScientific(a, 2)
  else: return (false, value)
  if f < 0.0: s = "-" & s
  (true, s)

proc formattedCellValue*(f: XlsxFile, rawV: string, effType: CellType,
    styleIdx: int): string =
  ## Port of excelize `formattedValue`: raw when unstyled, unresolvable,
  ## custom (Phase C), or unrenderable; otherwise the builtin rendering.
  let id = numFmtIdFor(f.styles, styleIdx)
  if id < 0: return rawV
  if f.styles.numFmts.hasKey(id): return rawV # custom: Phase C
  let (ok, text) = formatBuiltin(rawV, id, effType, f.date1904)
  if ok: text else: rawV
