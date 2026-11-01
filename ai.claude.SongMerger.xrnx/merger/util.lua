-- Small shared helpers without dependencies on song state.

local M = {}

M.TOOL_NAME = 'Song Merger'

---Prints a prefixed message to the Renoise scripting console.
---@param fmt string
function M.log(fmt, ...)
  print(('[SongMerger] ' .. fmt):format(...))
end

---@param value number
---@return integer
function M.round(value)
  return math.floor(value + 0.5)
end

---Shortens a string for fixed-width dialog columns.
---@param text string
---@param max_length integer
---@return string
function M.ellipsize(text, max_length)
  if #text <= max_length then
    return text
  end
  return text:sub(1, max_length - 1) .. '~'
end

---Returns the sorted keys of a set-like table.
---@param set table<integer, any>
---@return integer[]
function M.sorted_keys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---File name of a song without folder and extension.
---@param path string
---@return string
function M.song_name(path)
  local name = path:match('([^/\\]+)$') or path
  return (name:gsub('%.xrns$', ''))
end

---Normalizes a file path for comparisons across platforms.
---@param path string
---@return string
function M.normalize_path(path)
  local normalized = path:gsub('\\', '/')
  if os.platform() ~= 'LINUX' then
    normalized = normalized:lower()
  end
  return normalized
end

---Returns a temp file path with the given extension. Renoise deletes these files on exit.
---@param extension string without leading dot
---@return string
function M.temp_file(extension)
  local name = os.tmpname(extension)
  if not name:find('%.' .. extension .. '$') then
    name = name .. '.' .. extension
  end
  return name
end

---Calls `on_closed` once when the dialog gets closed by the window close button.
---Custom dialogs have no close notifier, so the dialog's visibility is polled on idle.
---@param get_dialog fun(): renoise.Dialog|nil
---@param is_finished fun(): boolean true when the dialog was closed by one of its own buttons
---@param on_closed fun()
function M.watch_dialog(get_dialog, is_finished, on_closed)
  local idle = renoise.tool().app_idle_observable
  local function check()
    local dialog = get_dialog()
    if is_finished() then
      idle:remove_notifier(check)
    elseif dialog and not dialog.visible then
      idle:remove_notifier(check)
      on_closed()
    end
  end
  idle:add_notifier(check)
end

---Sets a property and ignores errors (e.g. properties not available for a track type).
---@param object userdata
---@param key string
---@param value any
---@return boolean ok
function M.try_set(object, key, value)
  local ok = pcall(function()
    object[key] = value
  end)
  return ok
end

return M
