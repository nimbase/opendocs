# Main API entry point. Per-format modules are imported separately;
# this file re-exports the shared plumbing plus each format module.

import opendocs/zip
import opendocs/docx

export zip
export docx

proc add*(x, y: int): int =
  ## Template placeholder (kept until format modules land).
  return x + y
