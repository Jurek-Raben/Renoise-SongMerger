-- Captures everything the plan needs from the currently loaded (merge) song into plain Lua data and temp files.

local ProcessSlicer = require('merger.process_slicer')
local Routing = require('merger.routing')
local Util = require('merger.util')

local M = {}

---@class DeviceData
---@field index integer
---@field path string
---@field name string
---@field display_name string
---@field is_active boolean
---@field is_maximized boolean
---@field preset_data string
---@field param_names string[]
---@field param_values number[]
---@field is_native boolean

---@class TrackData
---@field index integer
---@field type string
---@field name string
---@field parent integer|nil
---@field props table<string, any>
---@field column_names string[]
---@field column_mutes boolean[]
---@field mixer table<string, number>
---@field devices DeviceData[] devices from index 2 on (index 1 is the mixer)
---@field automated { device: integer, param: integer }[]

---@class InstrumentData
---@field index integer
---@field name string
---@field file string|nil nil for empty instruments (not exported)
---@field chain_routes (integer|false)[] per sample device chain: source track index or false for "current track"
---@field plugin InstrumentPluginData|nil

---@class InstrumentPluginData
---@field alias_instrument_index integer
---@field alias_fx_track_index integer
---@field alias_fx_device_index integer
---@field midi_output_routing_index integer

---@class PatternData
---@field number_of_lines integer
---@field name string
---@field tracks table<integer, { lines: table<integer, table>, automation: table[] }>

---@class ExportData
---@field file_name string merge song path
---@field master_index integer
---@field track_count integer
---@field tracks table<integer, TrackData>
---@field instruments table<integer, InstrumentData>
---@field master_devices table<integer, DeviceData>
---@field sequence integer[]|nil source pattern index per sequence slot
---@field slot_mutes table<integer, table<integer, boolean>>|nil sequence index -> track index -> muted
---@field patterns table<integer, PatternData>|nil

-- Track properties copied 1:1 when the target track type supports them.
local TRACK_PROPS = {
  'color',
  'color_blend',
  'mute_state',
  'collapsed',
  'output_delay',
  'visible_note_columns',
  'visible_effect_columns',
  'volume_column_visible',
  'panning_column_visible',
  'delay_column_visible',
  'sample_effects_column_visible',
}

---@param device renoise.AudioDevice
---@param index integer
---@return DeviceData
local function capture_device(device, index)
  local names, values = {}, {}
  for param_index, param in ipairs(device.parameters) do
    names[param_index] = param.name
    values[param_index] = param.value
  end
  return {
    index = index,
    path = device.device_path,
    name = device.name,
    display_name = device.display_name,
    is_active = device.is_active,
    is_maximized = device.is_maximized,
    preset_data = device.active_preset_data,
    param_names = names,
    param_values = values,
    is_native = Routing.is_native_device(device.device_path),
  }
end

---@param track renoise.Track
---@param index integer
---@param parent integer|nil
---@return TrackData
local function capture_track(track, index, parent)
  local props = {}
  for _, key in ipairs(TRACK_PROPS) do
    local ok, value = pcall(function()
      return track[key]
    end)
    if ok then
      props[key] = value
    end
  end
  if track.type == renoise.Track.TRACK_TYPE_GROUP then
    props.group_collapsed = track.group_collapsed
  end
  props.output_routing = track.output_routing

  local column_names, column_mutes = {}, {}
  for column = 1, track.max_note_columns do
    column_names[column] = track:column_name(column)
    column_mutes[column] = track:column_is_muted(column)
  end

  local devices = {}
  local automated = {}
  for device_index, device in ipairs(track.devices) do
    if device_index > 1 then
      devices[#devices + 1] = capture_device(device, device_index)
    end
    for param_index, param in ipairs(device.parameters) do
      if param.is_automated then
        automated[#automated + 1] = { device = device_index, param = param_index }
      end
    end
  end

  return {
    index = index,
    type = track.type,
    name = track.name,
    parent = parent,
    props = props,
    column_names = column_names,
    column_mutes = column_mutes,
    mixer = {
      prefx_volume = track.prefx_volume.value,
      prefx_panning = track.prefx_panning.value,
      prefx_width = track.prefx_width.value,
      postfx_volume = track.postfx_volume.value,
      postfx_panning = track.postfx_panning.value,
    },
    devices = devices,
    automated = automated,
  }
end

---True when an instrument cannot produce sound: no samples, no plugin and no MIDI output device.
---@param instrument renoise.Instrument
---@return boolean
local function is_empty_instrument(instrument)
  return #instrument.samples == 0
    and not instrument.plugin_properties.plugin_loaded
    and instrument.midi_output_properties.device_name == ''
end

---Saves an instrument to a temp .xrni file and captures its routings.
---Empty instruments are not saved (`file` is nil); the importer maps them to the merge separator instrument.
---@param song renoise.Song
---@param index integer
---@param track_names string[]
---@return InstrumentData
local function capture_instrument(song, index, track_names)
  local instrument = song:instrument(index)
  if is_empty_instrument(instrument) then
    return { index = index, name = instrument.name, file = nil, chain_routes = {}, plugin = nil }
  end
  local file = Util.temp_file('xrni')
  song.selected_instrument_index = index
  if not renoise.app():save_instrument(file) then
    error(('Could not export instrument %02X "%s"'):format(index - 1, instrument.name))
  end

  local chain_routes = {}
  for chain_index, chain in ipairs(instrument.sample_device_chains) do
    local target =
      Routing.track_index_from_chain_routing(chain.output_routing, chain.available_output_routings, track_names)
    chain_routes[chain_index] = target or false
  end

  local plugin = instrument.plugin_properties
  return {
    index = index,
    name = instrument.name,
    file = file,
    chain_routes = chain_routes,
    plugin = {
      alias_instrument_index = plugin.alias_instrument_index,
      alias_fx_track_index = plugin.alias_fx_track_index,
      alias_fx_device_index = plugin.alias_fx_device_index,
      midi_output_routing_index = plugin.midi_output_routing_index,
    },
  }
end

---@param line renoise.PatternLine
---@param note_columns integer
---@param effect_columns integer
---@return table|nil
local function capture_line(line, note_columns, effect_columns)
  if line.is_empty then
    return nil
  end
  local notes, effects = {}, {}
  for column = 1, note_columns do
    local note = line:note_column(column)
    if not note.is_empty then
      notes[column] = {
        note = note.note_value,
        instrument = note.instrument_value,
        volume = note.volume_string,
        panning = note.panning_string,
        delay = note.delay_value,
        effect_number = note.effect_number_value,
        effect_amount = note.effect_amount_value,
      }
    end
  end
  for column = 1, effect_columns do
    local effect = line:effect_column(column)
    if not effect.is_empty then
      effects[column] = { number = effect.number_value, amount = effect.amount_value }
    end
  end
  return { notes = notes, effects = effects }
end

---@param automation renoise.PatternTrackAutomation
---@return table
local function capture_automation(automation)
  local points = {}
  for _, point in ipairs(automation.points) do
    points[#points + 1] = { time = point.time, value = point.value, scaling = point.scaling }
  end
  return { playmode = automation.playmode, points = points }
end

---@param song renoise.Song
---@param track_indices integer[]
---@param export ExportData
local function capture_patterns(song, track_indices, export)
  local sequence = {}
  local slot_mutes = {}
  local patterns = {}
  local pattern_sequence = song.sequencer.pattern_sequence
  for sequence_index, pattern_index in ipairs(pattern_sequence) do
    ProcessSlicer.step(('Exporting song data: sequence %d / %d'):format(sequence_index, #pattern_sequence))
    sequence[sequence_index] = pattern_index
    for _, track_index in ipairs(track_indices) do
      if song.sequencer:track_sequence_slot_is_muted(track_index, sequence_index) then
        slot_mutes[sequence_index] = slot_mutes[sequence_index] or {}
        slot_mutes[sequence_index][track_index] = true
      end
    end
    if not patterns[pattern_index] then
      local pattern = song:pattern(pattern_index)
      local pattern_data = {
        number_of_lines = pattern.number_of_lines,
        name = pattern.name,
        tracks = {},
      }
      for _, track_index in ipairs(track_indices) do
        ProcessSlicer.step()
        local track = song:track(track_index)
        local pattern_track = pattern:track(track_index)
        local lines = {}
        if not pattern_track.is_empty then
          local note_columns = track.visible_note_columns
          local effect_columns = track.visible_effect_columns
          for line_index, line in ipairs(pattern_track:lines_in_range(1, pattern.number_of_lines)) do
            lines[line_index] = capture_line(line, note_columns, effect_columns)
          end
        end
        local automation = {}
        for _, ref in ipairs(export.tracks[track_index].automated) do
          local param = track:device(ref.device):parameter(ref.param)
          local found = pattern_track:find_automation(param)
          if found then
            local data = capture_automation(found)
            data.device = ref.device
            data.param = ref.param
            automation[#automation + 1] = data
          end
        end
        pattern_data.tracks[track_index] = { lines = lines, automation = automation }
      end
      patterns[pattern_index] = pattern_data
    end
  end
  export.sequence = sequence
  export.slot_mutes = slot_mutes
  export.patterns = patterns
end

---Exports all data for the given plan from the current song.
---@param info MergeSongInfo
---@param plan MergePlan
---@return ExportData
function M.export(info, plan)
  local song = renoise.song()
  local selected_instrument = song.selected_instrument_index

  ---@type ExportData
  local export = {
    file_name = info.file_name,
    master_index = info.master_index,
    track_count = #song.tracks,
    tracks = {},
    instruments = {},
    master_devices = {},
  }

  local all_tracks = {}
  for _, index in ipairs(plan.tracks) do
    all_tracks[#all_tracks + 1] = index
  end
  for _, index in ipairs(plan.sends) do
    all_tracks[#all_tracks + 1] = index
  end
  for position, index in ipairs(all_tracks) do
    ProcessSlicer.step(('Exporting tracks: %d / %d'):format(position, #all_tracks))
    export.tracks[index] = capture_track(song:track(index), index, info.tracks[index].parent)
  end

  local master = song:track(info.master_index)
  for _, device_index in ipairs(plan.master_devices) do
    export.master_devices[device_index] = capture_device(master:device(device_index), device_index)
  end

  local names = {}
  for index, track in ipairs(song.tracks) do
    names[index] = track.name
  end
  for position, index in ipairs(plan.instruments) do
    ProcessSlicer.step(('Exporting instruments: %d / %d'):format(position, #plan.instruments), true)
    export.instruments[index] = capture_instrument(song, index, names)
  end
  song.selected_instrument_index = selected_instrument

  if plan.import_patterns then
    capture_patterns(song, all_tracks, export)
  end

  Util.log(
    'Exported %d tracks, %d instruments, %d master devices',
    #all_tracks,
    #plan.instruments,
    #plan.master_devices
  )
  return export
end

return M
