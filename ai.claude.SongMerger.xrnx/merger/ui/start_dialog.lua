-- First dialog: explains that the current song gets reloaded and asks for confirmation.
-- Return and Esc cancel; continuing requires clicking the (red) Continue button.

local Widgets = require('merger.ui.widgets')

local M = {}

local TEXT_WIDTH = 460

---@param target_path string
---@param merge_path string
---@param on_continue fun()
---@param on_cancel fun()
function M.show(target_path, merge_path, on_continue, on_cancel)
  local vb = renoise.ViewBuilder()
  local close

  local function cancel()
    close()
    on_cancel()
  end

  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    Widgets.header(vb, 'Merge a song into the current song'),
    Widgets.section(vb, nil, {
      Widgets.info_row(vb, 'Current song', Widgets.basename(target_path), { font = 'bold' }),
      vb:text { text = target_path, style = 'disabled', width = TEXT_WIDTH },
      vb:space { height = 4 },
      Widgets.info_row(vb, 'Song to merge', Widgets.basename(merge_path), { font = 'bold' }),
      vb:text { text = merge_path, style = 'disabled', width = TEXT_WIDTH },
    }, TEXT_WIDTH + 12),
    Widgets.section(vb, 'What happens now', {
      vb:multiline_text {
        width = TEXT_WIDTH,
        height = 92,
        text = '1. The song to merge is loaded temporarily, so its tracks can be analyzed.\n'
          .. '2. You choose tracks, send routings and master FX.\n'
          .. '3. The current song is reloaded from disk and the selection is merged into it.\n\n'
          .. 'Unsaved changes of the current song are lost unless you save them when Renoise asks.',
      },
    }, TEXT_WIDTH + 12),
    Widgets.footer(vb, {
      Widgets.button(vb, { text = 'Cancel', notifier = cancel, tooltip = 'Return / Esc' }),
      Widgets.button(vb, {
        text = 'Continue',
        kind = 'danger',
        notifier = function()
          close()
          on_continue()
        end,
      }),
    }),
  }

  close = Widgets.show_dialog('Start', content, { ['return'] = cancel, esc = cancel }, on_cancel)
end

return M
