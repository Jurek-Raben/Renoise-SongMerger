-- Shared building blocks for a consistent dialog look.

local Util = require('merger.util')

local M = {}

M.DANGER_COLOR = { 190, 45, 45 }
M.PRIMARY_COLOR = 'selected_button_back'
M.MARGIN = 10
M.SPACING = 8
M.BUTTON_WIDTH = 96
M.BUTTON_HEIGHT = 24

---Theme color with optional alpha, usable in canvas drawing.
---@param name string theme color name, e.g. 'body_font'
---@param alpha integer|nil 0-255
---@return integer[]
function M.theme_color(name, alpha)
  local ok, color = pcall(function()
    return renoise.app().theme.colors[name]
  end)
  if not ok or type(color) ~= 'table' then
    color = { 128, 128, 128 }
  end
  return { color[1], color[2], color[3], alpha or 255 }
end

---@param path string
---@return string
function M.basename(path)
  return path:match('([^/\\]+)$') or path
end

---Big title with an optional muted subtitle.
---@param vb renoise.ViewBuilder
---@param title string
---@param subtitle string|nil
function M.header(vb, title, subtitle)
  local column = vb:column {
    spacing = 2,
    vb:text { text = title, font = 'big', style = 'strong' },
  }
  if subtitle then
    column:add_child(vb:text { text = subtitle, style = 'disabled' })
  end
  return column
end

---Framed section with a bold title.
---@param vb renoise.ViewBuilder
---@param title string|nil
---@param views renoise.Views.View[]
---@param width integer|string|nil
function M.section(vb, title, views, width)
  local column = vb:column {
    background = 'group',
    margin = 6,
    spacing = 4,
    width = width,
  }
  if title then
    column:add_child(vb:text { text = title, font = 'bold' })
  end
  for _, view in ipairs(views) do
    column:add_child(view)
  end
  return column
end

---Label/value line for overview blocks.
---@param vb renoise.ViewBuilder
---@param label string
---@param value string
---@param options { label_width: integer|nil, style: string|nil, font: string|nil }|nil
function M.info_row(vb, label, value, options)
  options = options or {}
  return vb:row {
    vb:text { text = label, width = options.label_width or 120, style = 'disabled' },
    vb:text { text = value, style = options.style or 'normal', font = options.font or 'normal' },
  }
end

---Dialog button. `kind` is 'primary', 'danger' or nil.
---@param vb renoise.ViewBuilder
---@param spec { text: string, kind: string|nil, width: integer|nil, notifier: fun(), tooltip: string|nil }
function M.button(vb, spec)
  local color = nil
  if spec.kind == 'primary' then
    color = M.PRIMARY_COLOR
  elseif spec.kind == 'danger' then
    color = M.DANGER_COLOR
  end
  return vb:button {
    text = spec.text,
    width = spec.width or M.BUTTON_WIDTH,
    height = M.BUTTON_HEIGHT,
    color = color,
    font = spec.kind and 'bold' or 'normal',
    tooltip = spec.tooltip,
    notifier = spec.notifier,
  }
end

---Right aligned button bar.
---@param vb renoise.ViewBuilder
---@param buttons renoise.Views.View[]
function M.footer(vb, buttons)
  local aligner = vb:horizontal_aligner {
    mode = 'right',
    spacing = 6,
    width = '100%',
  }
  for _, button in ipairs(buttons) do
    aligner:add_child(button)
  end
  return aligner
end

---Small filled circle, e.g. as status indicator.
---@param vb renoise.ViewBuilder
---@param color integer[]
---@param size integer|nil
function M.dot(vb, color, size)
  size = size or 12
  return vb:canvas {
    width = size,
    height = size,
    render = function(context)
      context.fill_color = color
      context:begin_path()
      context:arc(size / 2, size / 2, size / 2 - 1, 0, math.pi * 2, false)
      context:fill()
    end,
  }
end

---Key handler mapping key names (e.g. 'esc', 'return') to actions. Other keys are passed on to Renoise.
---@param actions table<string, fun()>
---@return fun(dialog: renoise.Dialog, key: KeyEvent): KeyEvent|nil
function M.key_handler(actions)
  return function(_, key)
    local action = actions[key.name]
    if action then
      action()
      return nil
    end
    return key
  end
end

---Shows a custom dialog that reports a close via the window button as `on_closed`.
---Returns a `close` function for the dialog's own buttons (which suppresses `on_closed`).
---@param title string
---@param content renoise.Views.View
---@param keys table<string, fun()>|nil
---@param on_closed fun()|nil
---@return fun() close
function M.show_dialog(title, content, keys, on_closed)
  local dialog = nil
  local finished = false
  local function close()
    finished = true
    if dialog and dialog.visible then
      dialog:close()
    end
  end
  dialog = renoise.app():show_custom_dialog(Util.TOOL_NAME .. ' - ' .. title, content, M.key_handler(keys or {}))
  if on_closed then
    Util.watch_dialog(function()
      return dialog
    end, function()
      return finished
    end, function()
      finished = true
      on_closed()
    end)
  end
  return close
end

return M
