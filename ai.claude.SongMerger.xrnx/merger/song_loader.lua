-- Loads a song and calls back once it is ready. The tool's Lua state survives song changes, song objects don't.

local Util = require('merger.util')

local M = {}

local pending = nil

local function remove_notifiers()
  local tool = renoise.tool()
  if pending and pending.on_new_document and tool.app_new_document_observable:has_notifier(pending.on_new_document) then
    tool.app_new_document_observable:remove_notifier(pending.on_new_document)
  end
  if pending and pending.on_idle and tool.app_idle_observable:has_notifier(pending.on_idle) then
    tool.app_idle_observable:remove_notifier(pending.on_idle)
  end
end

---Drops a pending load (e.g. when the user cancelled Renoise's "save changes?" prompt).
function M.cancel()
  remove_notifiers()
  pending = nil
end

---Loads `path` and calls `callback(true)` one idle tick after the song is available,
---or `callback(false, message)` when another song than expected was loaded.
---@param path string
---@param callback fun(ok: boolean, message: string|nil)
function M.load(path, callback)
  M.cancel()
  local request = {}
  pending = request

  request.on_idle = function()
    remove_notifiers()
    pending = nil
    local loaded = renoise.song().file_name
    if Util.normalize_path(loaded) == Util.normalize_path(path) then
      callback(true)
    else
      callback(false, ('Expected "%s" but "%s" was loaded'):format(path, loaded))
    end
  end

  request.on_new_document = function()
    renoise.tool().app_new_document_observable:remove_notifier(request.on_new_document)
    request.on_new_document = nil
    renoise.tool().app_idle_observable:add_notifier(request.on_idle)
  end

  renoise.tool().app_new_document_observable:add_notifier(request.on_new_document)
  renoise.app():load_song(path)
end

return M
