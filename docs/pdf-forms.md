# PDF Forms

Module: `src/opendocs/pdf/forms.nim`. All writes are `base: string -> string` incremental + `/NeedAppearances`.

```nim
import opendocs/pdf

var d = openDoc(readFile("form.pdf"))
echo fieldNames(d)
echo getField(d, "name").value
echo isChecked(d, "chk")
```

## Model

- `FieldKind(fkText/fkCheckbox/fkRadio/fkDropdown/fkListBox/fkSignature/fkPushButton/fkUnknown)`.
- `FieldOption(value, display)`, `FieldWidget(page, rect, appearance)`.
- `FormField(name, label, kind, value, defaultValue, options, maxLen, readOnly, required, multiline, password, combo, editable, fontName/Size, align, widgets)`.
- Internals: `PathStep`, `Inh(ft, v, dv, da, tu, opt, ff, q, maxLen, ...)`, `RawField(node, nodeRef, path, fullName, inh, widgetRefs, selfWidget)`.

## Read

- `rawFields`, `formFields` (dotted names, `/Parent` inherit, `/I` over `/V`, on-states), `fieldNames`, `getField`, `isChecked`, `kindOf`.

## Write

- `fillText(base, name, value): string`
- `setCheck(base, name, checked): string`
- `selectRadio(base, group, option|Off): string`
- `selectChoice(base, name, choice)` — display|export, editable combo
- `selectChoices(base, name, choices)` — `/V + /I`
- `resetFields(base, names): string` — to `/DV`
- `flattenFields(base, only): string` — bake text/check/dot to content, drop annots, prune tree, drop empty `/AcroForm`.
- `calcOrder(d): seq[string]` — `/CO` order, fields not in it appended.

## XFDF (`pdf/xfdf.nim`, openparser-backed)

- `exportXfdf(d): string`, `importXfdf(base, xfdf): string` — field values plus text/square/highlight/ink annotations and URI-link subset (internal links via a documented extension). No JS, no XFA. Malformed XFDF fails, never partial-applies.

## Redact (`pdf/redact.nim`)

- `markRedactions(base, rects): string` — black-rect overlay (mark only).
- `applyRedactions(base, rects): string` — content-stream surgery: glyph runs and image-Do regions removed, form-Do condemned whole. True removal, not cover-up.
- `verifyNoFauxRedaction(data, rects)` — fails when covered text still extracts or covered pixels still decode. Shares the analysis path with apply.

See `examples/example_pdf_forms.nim`, `tests/t_pdf_forms.nim`, `t_pdf_formrealdoc.nim`, `t_pdf_formxobject.nim`, `t_pdf_xfdf.nim`, `t_pdf_redact.nim`.
