-- Reads the structure of the currently loaded (merge) song into plain Lua data.
-- The result must not contain any references to song objects, because the song gets unloaded afterwards.

local ProcessSlicer = require('merger.process_slicer')
local Routing = require('merger.routing')

local M = {}

local TYPE_NAMES = {
  [renoise.Track.TRACK_TYPE_SEQUENCER] = 'sequencer',
  [renoise.Track.TRACK_TYPE_MASTER] = 'master',
  [renoise.Track.TRACK_TYPE_SEND] = 'send',
  [renoise.Track.TRACK_TYPE_GROUP] = 'group',
}

---@class MergeTrackInfo
---@field index integer
---@field name string
---@field type 'sequencer'|'master'|'send'|'group'
---@field parent integer|nil direct parent group index
---@field depth integer group nesting depth
---@field members integer[] direct members (groups only)
---@field output_routing string
---@field color integer[] track color { r, g, b }
---@field sends integer[] send track indices targeted by #Send devices
---@field meta_out integer[] track indices targeted by meta devices on this track
---@field meta_in integer[] track indices whose meta devices target this track
---@field instruments table<integer, boolean> used instrument indices

---@class MergeInstrumentInfo
---@field index integer
---@field name string
---@field route_tracks integer[] tracks targeted by sample FX chain routings or plugin FX aliases

---@class MergeSongInfo
---@field file_name string
---@field master_index integer
---@field tracks MergeTrackInfo[]
---@field instruments MergeInstrumentInfo[]
---@field master_devices { index: integer, name: string, display_name: string, meta_out: integer[] }[]

---@param list integer[]
---@param value integer
local function add_unique(list, value)
  for _, existing in ipairs(list) do
    if existing == value then
      return
    end
  end
  list[#list + 1] = value
end

---@param device renoise.AudioDevice
---@return string[]
local function param_names(device)
  local names = {}
  for index, param in ipairs(device.parameters) do
    names[index] = param.name
  end
  return names
end

---Builds the group hierarchy. Members of a group are always placed contiguously left of the group track.
---ASSUMPTION: `#group.members` includes nested members, so the member range is (g - #members) .. (g - 1).
---@param song renoise.Song
---@param tracks MergeTrackInfo[]
local function resolve_groups(song, tracks)
  for index, track in ipairs(song.tracks) do
    if track.type == renoise.Track.TRACK_TYPE_GROUP then
      local first = index - #track.members
      for member = index - 1, first, -1 do
        if tracks[member].parent == nil then
          tracks[member].parent = index
        end
      end
    end
  end
  for _, info in ipairs(tracks) do
    if info.parent then
      add_unique(tracks[info.parent].members, info.index)
    end
  end
  -- Members were collected right to left; restore source order.
  for _, info in ipairs(tracks) do
    table.sort(info.members)
  end
  for _, info in ipairs(tracks) do
    local depth = 0
    local parent = info.parent
    while parent do
      depth = depth + 1
      parent = tracks[parent].parent
    end
    info.depth = depth
  end
end

---Collects send, meta and instrument references of a device chain.
---@param devices renoise.AudioDevice[]
---@param own_index integer
---@param master_index integer
---@return integer[] sends
---@return integer[] meta_out
---@return integer[] instruments
local function scan_devices(devices, own_index, master_index)
  local sends, meta_out, instruments = {}, {}, {}
  for device_index = 2, #devices do
    local device = devices[device_index]
    local names = param_names(device)
    for _, param_index in ipairs(Routing.receiver_params(device.name, names)) do
      local value = device.parameters[param_index].value
      add_unique(sends, Routing.send_track_index_from_value(value, master_index))
    end
    for _, destination in ipairs(Routing.track_destinations(device.name, names)) do
      local target = Routing.track_index_from_value(device.parameters[destination.track].value)
      if target and target ~= own_index then
        add_unique(meta_out, target)
      end
    end
    for _, param_index in ipairs(Routing.instrument_params(device.name, names)) do
      local instrument = Routing.instrument_index_from_value(device.parameters[param_index].value)
      if instrument then
        add_unique(instruments, instrument)
      end
    end
  end
  return sends, meta_out, instruments
end

---Marks all instruments used in the note columns of sequencer tracks.
---@param song renoise.Song
---@param tracks MergeTrackInfo[]
local function scan_pattern_instruments(song, tracks)
  local visited = {}
  local sequence = song.sequencer.pattern_sequence
  for sequence_index, pattern_index in ipairs(sequence) do
    if not visited[pattern_index] then
      visited[pattern_index] = true
      local pattern = song:pattern(pattern_index)
      for track_index, track in ipairs(song.tracks) do
        ProcessSlicer.step(('Scanning instruments: sequence %d / %d'):format(sequence_index, #sequence))
        if track.type == renoise.Track.TRACK_TYPE_SEQUENCER then
          local pattern_track = pattern:track(track_index)
          if not pattern_track.is_empty then
            local columns = track.visible_note_columns
            local used = tracks[track_index].instruments
            for _, line in ipairs(pattern_track:lines_in_range(1, pattern.number_of_lines)) do
              if not line.is_empty then
                for column = 1, columns do
                  local value = line:note_column(column).instrument_value
                  if value ~= renoise.PatternLine.EMPTY_INSTRUMENT then
                    used[value + 1] = true
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

---@param song renoise.Song
---@return string[]
local function track_names(song)
  local names = {}
  for index, track in ipairs(song.tracks) do
    names[index] = track.name
  end
  return names
end

---Analyzes the current song.
---@return MergeSongInfo
function M.analyze()
  local song = renoise.song()
  ---@type MergeSongInfo
  local info = {
    file_name = song.file_name,
    master_index = 0,
    tracks = {},
    instruments = {},
    master_devices = {},
  }

  for index, track in ipairs(song.tracks) do
    if track.type == renoise.Track.TRACK_TYPE_MASTER then
      info.master_index = index
    end
    info.tracks[index] = {
      index = index,
      name = track.name,
      type = TYPE_NAMES[track.type],
      parent = nil,
      depth = 0,
      members = {},
      output_routing = track.output_routing,
      color = track.color,
      sends = {},
      meta_out = {},
      meta_in = {},
      instruments = {},
    }
  end
  resolve_groups(song, info.tracks)

  for index, track in ipairs(song.tracks) do
    ProcessSlicer.step(('Scanning devices: track %d / %d'):format(index, #song.tracks))
    local sends, meta_out, instruments = scan_devices(track.devices, index, info.master_index)
    local track_info = info.tracks[index]
    track_info.sends = sends
    track_info.meta_out = meta_out
    for _, instrument in ipairs(instruments) do
      track_info.instruments[instrument] = true
    end
    for _, target in ipairs(meta_out) do
      add_unique(info.tracks[target].meta_in, index)
    end
  end

  local master = song:track(info.master_index)
  for device_index = 2, #master.devices do
    local device = master.devices[device_index]
    local _, meta_out = scan_devices({ master.devices[1], device }, info.master_index, info.master_index)
    info.master_devices[#info.master_devices + 1] = {
      index = device_index,
      name = device.name,
      display_name = device.display_name,
      meta_out = meta_out,
    }
  end

  scan_pattern_instruments(song, info.tracks)

  local names = track_names(song)
  for index, instrument in ipairs(song.instruments) do
    local route_tracks = {}
    for _, chain in ipairs(instrument.sample_device_chains) do
      local target =
        Routing.track_index_from_chain_routing(chain.output_routing, chain.available_output_routings, names)
      if target then
        add_unique(route_tracks, target)
      end
    end
    -- ASSUMPTION: alias_fx_track_index is a 1-based track index, 0 = no FX alias.
    local alias_track = instrument.plugin_properties.alias_fx_track_index
    if alias_track > 0 then
      add_unique(route_tracks, alias_track)
    end
    info.instruments[index] = {
      index = index,
      name = instrument.name,
      route_tracks = route_tracks,
    }
  end

  -- Remove references to instrument slots that do not exist (stale pattern data).
  for _, track_info in ipairs(info.tracks) do
    for instrument in pairs(track_info.instruments) do
      if not info.instruments[instrument] then
        track_info.instruments[instrument] = nil
      end
    end
  end

  return info
end

return M
