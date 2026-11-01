-- Tool options. Renoise loads/saves them automatically (preferences.xml in the tool folder).

local M = {}

local preferences = renoise.Document.create('SongMergerPreferences') {
  show_debug_info = false,
}

renoise.tool().preferences = preferences

M.document = preferences

---@return boolean
function M.show_debug_info()
  return preferences.show_debug_info.value
end

return M
