-- Dialog 2: choose single master FX devices of the merge song.

local Util = require('merger.util')
local Widgets = require('merger.ui.widgets')

local M = {}

local ROW_WIDTHS = {
  index = 28,
  name = 220,
  device = 160,
  routing = 220,
}

---Shows the master FX selection dialog.
---@param info MergeSongInfo
---@param choices MergeChoices
---@param on_merge fun(choices: MergeChoices)
---@param on_back fun(choices: MergeChoices)
---@param on_cancel fun()
function M.show(info, choices, on_merge, on_back, on_cancel)
  local vb = renoise.ViewBuilder()
  local close
  local boxes = {}
  local count_text = vb:text { style = 'disabled' }

  local function update_count()
    local selected = 0
    for _, device in ipairs(info.master_devices) do
      if choices.master_devices[device.index] then
        selected = selected + 1
      end
    end
    count_text.text = ('%d of %d devices selected'):format(selected, #info.master_devices)
  end

  local list = vb:column { spacing = 2 }
  list:add_child(vb:row {
    vb:space { width = 22 },
    vb:text { text = '#', width = ROW_WIDTHS.index, font = 'bold', style = 'disabled' },
    vb:text { text = 'Name', width = ROW_WIDTHS.name, font = 'bold', style = 'disabled' },
    vb:text { text = 'Device', width = ROW_WIDTHS.device, font = 'bold', style = 'disabled' },
    vb:text { text = 'Meta routing', width = ROW_WIDTHS.routing, font = 'bold', style = 'disabled' },
  })
  for _, device in ipairs(info.master_devices) do
    local targets = {}
    for _, index in ipairs(device.meta_out) do
      targets[#targets + 1] = info.tracks[index].name
    end
    local routing = #targets > 0 and ('to ' .. table.concat(targets, ', ')) or '-'
    local name = device.display_name ~= '' and device.display_name or device.name
    boxes[device.index] = vb:checkbox {
      value = choices.master_devices[device.index] == true,
      notifier = function(value)
        choices.master_devices[device.index] = value
        update_count()
      end,
    }
    list:add_child(vb:row {
      boxes[device.index],
      vb:text { text = ('%02d'):format(device.index - 1), width = ROW_WIDTHS.index, style = 'disabled' },
      vb:text { text = Util.ellipsize(name, 34), tooltip = name, width = ROW_WIDTHS.name, font = 'bold' },
      vb:text { text = Util.ellipsize(device.name, 26), tooltip = device.name, width = ROW_WIDTHS.device },
      vb:text {
        text = Util.ellipsize(routing, 34),
        tooltip = routing,
        width = ROW_WIDTHS.routing,
        style = #targets > 0 and 'normal' or 'disabled',
      },
    })
  end

  local function set_all(value)
    for index, box in pairs(boxes) do
      box.value = value
      choices.master_devices[index] = value
    end
    update_count()
  end

  local function cancel()
    close()
    on_cancel()
  end

  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    Widgets.header(vb, 'Select master FX', 'Merge song: ' .. info.file_name),
    vb:row {
      spacing = 4,
      Widgets.button(vb, { text = 'Select all', width = 84, notifier = function() set_all(true) end }),
      Widgets.button(vb, { text = 'Select none', width = 84, notifier = function() set_all(false) end }),
      vb:space { width = 12 },
      vb:vertical_aligner { mode = 'center', height = Widgets.BUTTON_HEIGHT, count_text },
    },
    Widgets.section(vb, nil, { list }),
    vb:text {
      text = 'Selected devices are appended to the end of the master track of the current song.',
      style = 'disabled',
    },
    Widgets.footer(vb, {
      Widgets.button(vb, {
        text = '< Back',
        notifier = function()
          close()
          on_back(choices)
        end,
      }),
      Widgets.button(vb, { text = 'Cancel', notifier = cancel }),
      Widgets.button(vb, {
        text = 'Merge',
        kind = 'primary',
        notifier = function()
          close()
          on_merge(choices)
        end,
      }),
    }),
  }

  update_count()
  close = Widgets.show_dialog('Master FX', content, { esc = cancel }, on_cancel)
end

return M
