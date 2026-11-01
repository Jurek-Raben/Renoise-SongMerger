-- Confirmation before the merge starts: what will be imported, incl. automatically added tracks.

local Widgets = require('merger.ui.widgets')

local M = {}

local WIDTH = 440

---@param info MergeSongInfo
---@param plan MergePlan
---@param on_merge fun()
---@param on_back fun()
function M.show(info, plan, on_merge, on_back)
  local vb = renoise.ViewBuilder()
  local close

  local function back()
    close()
    on_back()
  end

  local auto_added = vb:column { spacing = 1 }
  if #plan.auto_added == 0 then
    auto_added:add_child(vb:text { text = 'Nothing.', style = 'disabled' })
  end
  for _, entry in ipairs(plan.auto_added) do
    auto_added:add_child(vb:text { text = '+ ' .. entry, width = WIDTH })
  end

  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    Widgets.header(vb, 'Ready to merge', 'Merge song: ' .. info.file_name),
    Widgets.section(vb, 'Will be imported', {
      Widgets.info_row(vb, 'Tracks/groups', tostring(#plan.tracks), { font = 'bold' }),
      Widgets.info_row(vb, 'Send tracks', tostring(#plan.sends), { font = 'bold' }),
      Widgets.info_row(vb, 'Instruments', tostring(#plan.instruments), { font = 'bold' }),
      Widgets.info_row(vb, 'Master FX', tostring(#plan.master_devices), { font = 'bold' }),
      Widgets.info_row(vb, 'Song data', plan.import_patterns and 'yes, appended' or 'no', { font = 'bold' }),
    }, WIDTH + 12),
    Widgets.section(vb, 'Added automatically', { auto_added }, WIDTH + 12),
    vb:text {
      text = 'The current song is reloaded from disk before the merge.',
      style = 'disabled',
    },
    Widgets.footer(vb, {
      Widgets.button(vb, { text = '< Back', notifier = back }),
      Widgets.button(vb, {
        text = 'Merge',
        kind = 'primary',
        notifier = function()
          close()
          on_merge()
        end,
      }),
    }),
  }

  close = Widgets.show_dialog('Confirm', content, { esc = back }, on_back)
end

return M
