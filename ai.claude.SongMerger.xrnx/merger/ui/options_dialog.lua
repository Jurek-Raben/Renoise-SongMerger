-- Options dialog. Values are bound to the preferences document and saved by Renoise.

local Preferences = require('merger.preferences')
local Widgets = require('merger.ui.widgets')

local M = {}

local close = nil

function M.show()
  if close then
    close()
  end

  local vb = renoise.ViewBuilder()
  local function done()
    close()
    close = nil
  end

  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    Widgets.header(vb, 'Options'),
    Widgets.section(vb, 'Debugging', {
      vb:row {
        vb:checkbox { bind = Preferences.document.show_debug_info },
        vb:text { text = 'Show debug info', font = 'bold' },
      },
      vb:text {
        text = 'Adds technical details such as temporary file paths to the summary after a merge.',
        style = 'disabled',
      },
    }),
    Widgets.footer(vb, {
      Widgets.button(vb, { text = 'Close', kind = 'primary', notifier = done }),
    }),
  }

  close = Widgets.show_dialog('Options', content, { esc = done, ['return'] = done })
end

return M
