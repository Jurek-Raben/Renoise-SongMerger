-- Turns the user's choices from the dialogs into a complete, consistent import plan.

local Util = require('merger.util')

local M = {}

---@class MergeChoices
---@field selected table<integer, boolean> sequencer/group track index -> import
---@field keep_sends table<integer, boolean> sequencer/group track index -> keep send routing incl. send tracks
---@field import_patterns boolean
---@field master_devices table<integer, boolean> master device index -> import

---@class MergePlan
---@field tracks integer[] sequencer and group track indices, source order
---@field sends integer[] send track indices, source order
---@field instruments integer[] instrument indices, source order
---@field drop_sends table<integer, boolean> tracks whose send devices get bypassed
---@field master_devices integer[] master device indices, source order
---@field import_patterns boolean
---@field auto_added string[] human readable notes about tracks added automatically

---Creates default choices: nothing selected, sends kept, no song data, no master FX.
---@param info MergeSongInfo
---@return MergeChoices
function M.default_choices(info)
  local choices = {
    selected = {},
    keep_sends = {},
    import_patterns = false,
    master_devices = {},
  }
  for _, track in ipairs(info.tracks) do
    if track.type == 'sequencer' or track.type == 'group' then
      choices.selected[track.index] = false
      choices.keep_sends[track.index] = true
    end
  end
  return choices
end

---@param info MergeSongInfo
---@param choices MergeChoices
---@return MergePlan
function M.resolve(info, choices)
  local tracks = {}
  local sends = {}
  local instruments = {}
  local auto_added = {}

  local function add_track(index, reason)
    local track = info.tracks[index]
    if track == nil or track.type == 'master' then
      return false
    end
    local set = track.type == 'send' and sends or tracks
    if set[index] then
      return false
    end
    set[index] = true
    if reason then
      auto_added[#auto_added + 1] = ('%s (%s)'):format(track.name, reason)
    end
    return true
  end

  -- The dialog already cascades group selections to their children; deselected children stay excluded.
  for index, selected in pairs(choices.selected) do
    if selected then
      add_track(index)
    end
  end

  -- Repeat until stable: parents, sends, instruments and instrument routings can pull in further tracks.
  local changed = true
  while changed do
    changed = false
    for _, index in ipairs(Util.sorted_keys(tracks)) do
      local track = info.tracks[index]
      if track.parent and add_track(track.parent, 'parent group') then
        changed = true
      end
    end
    local all = {}
    for index in pairs(tracks) do
      all[#all + 1] = index
    end
    for index in pairs(sends) do
      all[#all + 1] = index
    end
    for _, index in ipairs(all) do
      local track = info.tracks[index]
      local keep = track.type == 'send' or choices.keep_sends[index] ~= false
      if keep then
        for _, send in ipairs(track.sends) do
          if add_track(send, 'send of ' .. track.name) then
            changed = true
          end
        end
      end
      for instrument in pairs(track.instruments) do
        if not instruments[instrument] then
          instruments[instrument] = true
          changed = true
        end
      end
    end
    for instrument in pairs(instruments) do
      for _, target in ipairs(info.instruments[instrument].route_tracks) do
        if add_track(target, 'routing of instrument ' .. info.instruments[instrument].name) then
          changed = true
        end
      end
    end
  end

  -- Meta devices on selected master FX that target non-imported tracks are reported by the importer.
  local drop_sends = {}
  for index in pairs(tracks) do
    if choices.keep_sends[index] == false then
      drop_sends[index] = true
    end
  end

  local master_devices = {}
  for index, selected in pairs(choices.master_devices) do
    if selected then
      master_devices[#master_devices + 1] = index
    end
  end
  table.sort(master_devices)

  return {
    tracks = Util.sorted_keys(tracks),
    sends = Util.sorted_keys(sends),
    instruments = Util.sorted_keys(instruments),
    drop_sends = drop_sends,
    master_devices = master_devices,
    import_patterns = choices.import_patterns,
    auto_added = auto_added,
  }
end

return M
