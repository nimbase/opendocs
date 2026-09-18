## Minimal XML string emitter for the docx writer.
##
## Deliberately tiny: a buffer plus open/close/empty/text helpers with
## escaping at the boundary (`xmlEscape` for text, `xmlAttrEscape` for
## attribute values). Attributes are prebuilt strings so call sites stay
## flat; `optAttr`/`flag` helpers keep conditional emission readable
## without `if` pyramids.

import openparser/xml

type
  XmlEmit* = object
    buf*: string

proc decl*(e: var XmlEmit) =
  ## XML declaration used on every standalone part.
  e.buf.add "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

func attr*(name, val: string): string =
  ## One escaped attribute chunk, including the leading space.
  " " & name & "=\"" & xmlAttrEscape(val) & "\""

func optAttr*(name, val: string): string =
  ## Attribute chunk, or "" when the value is unspecified.
  if val == "": "" else: attr(name, val)

func optAttrI*(name: string, v, unspec: int): string =
  ## Integer attribute chunk, or "" when `v` is the unspecified marker.
  if v == unspec: "" else: attr(name, $v)

proc open*(e: var XmlEmit, tag: string, attrs = "") =
  e.buf.add "<" & tag & attrs & ">"

proc close*(e: var XmlEmit, tag: string) =
  e.buf.add "</" & tag & ">"

proc empty*(e: var XmlEmit, tag: string, attrs = "") =
  e.buf.add "<" & tag & attrs & "/>"

proc flag*(e: var XmlEmit, tag: string, set: bool, attrs = "") =
  ## Empty on/off element, emitted only when set.
  if set: e.empty(tag, attrs)

proc text*(e: var XmlEmit, s: string) =
  e.buf.add xmlEscape(s)

proc elem*(e: var XmlEmit, tag: string, body: string, attrs = "") =
  ## Leaf element with escaped text body.
  e.open(tag, attrs)
  e.text(body)
  e.close(tag)
