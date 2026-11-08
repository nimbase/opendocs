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

See `examples/example_pdf_forms.nim`, `tests/t_pdf_forms.nim`, `t_pdf_formrealdoc.nim`, `t_pdf_formxobject.nim`.
