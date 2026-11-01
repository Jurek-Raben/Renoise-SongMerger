-- Inserts exported merge song data into the currently loaded (target) song and remaps all routings.

local ProcessSlicer = require('merger.process_slicer')
local Routing = require('merger.routing')
local Util = require('merger.util')

local M = {}

local TAG_PREFIX = '__songmerger_'
local ANCHOR_NAME = '__songmerger_anchor'
local PLACEHOLDER_DEVICE_PATH = 'Audio/Effects/Native/Gainer'

---@class ImportContext
---@field song renoise.Song
---@field export ExportData
---@field plan MergePlan
---@field track_map table<integer, integer> source track index -> target track index
---@field instrument_map table<integer, integer> source instrument index -> target instrument index
---@field master_device_map table<integer, integer> source master device index -> target master device index
---@field target_master integer
---@field warnings string[]
---@field sequence_slots integer|nil
---@field pattern_count integer|nil

---@param ctx ImportContext
local function warn(ctx, fmt, ...)
  local message = fmt:format(...)
  for _, existing in ipairs(ctx.warnings) do
    if existing == message then
      return
    end
  end
  ctx.warnings[#ctx.warnings + 1] = message
  Util.log('WARNING: %s', message)
end

---@param song renoise.Song
---@return integer
local function find_master(song)
  for index, track in ipairs(song.tracks) do
    if track.type == renoise.Track.TRACK_TYPE_MASTER then
      return index
    end
  end
  error('Target song has no master track')
end

---Label used for the separator instrument and the sequence section of the merged part.
---@param ctx ImportContext
---@return string
local function merge_label(ctx)
  return ('----- MERGE: %s -----'):format(Util.song_name(ctx.export.file_name))
end

---@param song renoise.Song
---@param name string
---@return integer|nil
local function find_named(song, name)
  for index, track in ipairs(song.tracks) do
    if track.name == name then
      return index
    end
  end
  return nil
end

---@param song renoise.Song
---@param source_index integer
---@return integer|nil
local function find_tagged(song, source_index)
  return find_named(song, TAG_PREFIX .. source_index)
end

---@param device renoise.AudioDevice
---@param param_index integer
---@param value number
---@return boolean ok
local function set_param(device, param_index, value)
  return pcall(function()
    device:parameter(param_index).value = value
  end)
end

---True when an instrument slot is unused (no name, samples, plugin or MIDI output).
---@param instrument renoise.Instrument
---@return boolean
local function is_blank_instrument(instrument)
  return instrument.name == ''
    and #instrument.samples == 0
    and not instrument.plugin_properties.plugin_loaded
    and instrument.midi_output_properties.device_name == ''
end

---Loads an .xrni into a new slot at the end of the instrument list and returns the loaded instrument's index.
---ASSUMPTION: load_instrument either replaces the selected (empty) instrument or inserts a new one and selects it.
---Both cases are handled: any blank placeholder left behind in the new range is deleted again.
---@param ctx ImportContext
---@param data InstrumentData
---@return integer
local function load_instrument_at_end(ctx, data)
  local song = ctx.song
  local first_new = #song.instruments + 1
  song:insert_instrument_at(first_new)
  song.selected_instrument_index = first_new
  if not renoise.app():load_instrument(data.file) then
    warn(ctx, 'Instrument "%s" could not be loaded', data.name)
  end
  local loaded = song.selected_instrument_index
  for index = #song.instruments, first_new, -1 do
    if index ~= loaded and is_blank_instrument(song:instrument(index)) then
      song:delete_instrument_at(index)
      if index < loaded then
        loaded = loaded - 1
      end
    end
  end
  return loaded
end

---Inserts a separator instrument followed by the merged instruments (loaded from the exported .xrni files).
---Empty instruments of the merge song are not imported; references to them point to the separator, which is
---silent just like the original empty instrument.
---@param ctx ImportContext
local function import_instruments(ctx)
  local song = ctx.song
  local count = #ctx.plan.instruments
  if count == 0 then
    return
  end
  if #song.instruments + count + 1 > renoise.Song.MAX_NUMBER_OF_INSTRUMENTS then
    error(('Too many instruments: target has %d, merge needs %d more'):format(#song.instruments, count + 1))
  end

  local separator_index = #song.instruments + 1
  local separator = song:insert_instrument_at(separator_index)
  separator.name = merge_label(ctx)

  for position, source_index in ipairs(ctx.plan.instruments) do
    ProcessSlicer.step(('Importing instruments: %d / %d'):format(position, count), true)
    local data = ctx.export.instruments[source_index]
    if data.file then
      ctx.instrument_map[source_index] = load_instrument_at_end(ctx, data)
    else
      ctx.instrument_map[source_index] = separator_index
    end
  end
end

---Creates a top-level sequencer track near the end of the track list. New tracks are inserted at its index,
---which keeps them outside of all existing groups. Inserting at the master's index would create a send track.
---@param song renoise.Song
---@return integer anchor_index
local function insert_anchor(song)
  local last_index = find_master(song) - 1
  local anchor = song:insert_track_at(last_index)
  anchor.name = ANCHOR_NAME
  local last = song:track(last_index + 1)
  if last.type == renoise.Track.TRACK_TYPE_SEQUENCER and last.group_parent == nil then
    -- Move the anchor behind the former last track, so imported tracks end up at the end.
    pcall(function()
      song:swap_tracks_at(last_index, last_index + 1)
    end)
  end
  local index = find_named(song, ANCHOR_NAME)
  while song:track(index).group_parent ~= nil do
    song:remove_track_from_group(index)
    index = find_named(song, ANCHOR_NAME)
  end
  return index
end

---Inserts all tracks (flat), rebuilds groups, appends send tracks and builds the track map.
---@param ctx ImportContext
local function import_tracks(ctx)
  local song = ctx.song
  local anchor_index = insert_anchor(song)

  -- Each new track is inserted left of the anchor, so the source order is kept.
  for _, source_index in ipairs(ctx.plan.tracks) do
    local data = ctx.export.tracks[source_index]
    local track
    if data.type == renoise.Track.TRACK_TYPE_GROUP then
      track = song:insert_group_at(anchor_index)
    else
      track = song:insert_track_at(anchor_index)
    end
    track.name = TAG_PREFIX .. source_index
    anchor_index = anchor_index + 1
  end
  song:delete_track_at(find_named(song, ANCHOR_NAME))

  -- Groups are processed in source order, so inner groups are complete before they get added to outer groups.
  for _, group_index in ipairs(ctx.plan.tracks) do
    if ctx.export.tracks[group_index].type == renoise.Track.TRACK_TYPE_GROUP then
      for _, member_index in ipairs(ctx.plan.tracks) do
        if ctx.export.tracks[member_index].parent == group_index then
          local ok, err = pcall(function()
            song:add_track_to_group(find_tagged(song, member_index), find_tagged(song, group_index))
          end)
          if not ok then
            warn(ctx, 'Could not add track "%s" to its group: %s', ctx.export.tracks[member_index].name, tostring(err))
          end
        end
      end
    end
  end

  for _, source_index in ipairs(ctx.plan.sends) do
    local track = song:insert_track_at(#song.tracks + 1)
    track.name = TAG_PREFIX .. source_index
  end

  ctx.target_master = find_master(song)
  ctx.track_map[ctx.export.master_index] = ctx.target_master
  local previous = 0
  for index, track in ipairs(song.tracks) do
    local source_index = tonumber(track.name:match('^' .. TAG_PREFIX .. '(%d+)$'))
    if source_index then
      ctx.track_map[source_index] = index
      track.name = ctx.export.tracks[source_index].name
      if source_index < previous and ctx.export.tracks[source_index].type ~= renoise.Track.TRACK_TYPE_SEND then
        warn(ctx, 'Track order inside groups differs from the merge song near "%s"', track.name)
      end
      previous = source_index
    end
  end
end

---Inserts a device and restores its state. Missing devices get a bypassed placeholder to keep device indices.
---@param ctx ImportContext
---@param track renoise.Track
---@param data DeviceData
---@return renoise.AudioDevice
local function insert_device(ctx, track, data)
  -- Instantiating plugins can take long, so each device gets its own time slice check.
  ProcessSlicer.step()
  local position = #track.devices + 1
  local ok, device = pcall(function()
    return track:insert_device_at(data.path, position)
  end)
  if not ok then
    warn(ctx, 'Device "%s" is not available, inserted a bypassed placeholder', data.name)
    device = track:insert_device_at(PLACEHOLDER_DEVICE_PATH, position)
    device.display_name = 'MISSING: ' .. data.name
    device.is_active = false
    return device
  end

  -- ASSUMPTION: active_preset_data restores the complete device state (incl. plugin chunks, Doofer chains,
  -- Formula code, custom LFO curves).
  if not Util.try_set(device, 'active_preset_data', data.preset_data) then
    warn(ctx, 'Could not restore preset data of "%s"', data.name)
  end
  if data.is_native then
    for param_index, value in ipairs(data.param_values) do
      set_param(device, param_index, value)
    end
  end
  Util.try_set(device, 'display_name', data.display_name)
  Util.try_set(device, 'is_active', data.is_active)
  Util.try_set(device, 'is_maximized', data.is_maximized)
  return device
end

---@param ctx ImportContext
---@param track renoise.Track
---@param data TrackData
local function configure_track(ctx, track, data)
  for key, value in pairs(data.props) do
    if key ~= 'output_routing' then
      Util.try_set(track, key, value)
    end
  end
  if data.parent == nil then
    local routing = data.props.output_routing
    local available = table.find(track.available_output_routings, routing)
    if available then
      track.output_routing = routing
    else
      warn(ctx, 'Output routing "%s" of track "%s" is not available', tostring(routing), data.name)
    end
  end
  for column = 1, math.min(#data.column_names, track.max_note_columns) do
    pcall(function()
      track:set_column_name(column, data.column_names[column])
      track:set_column_is_muted(column, data.column_mutes[column])
    end)
  end
  for key, value in pairs(data.mixer) do
    pcall(function()
      track[key].value = value
    end)
  end
  for _, device_data in ipairs(data.devices) do
    insert_device(ctx, track, device_data)
  end
end

---Remaps send receivers, meta device destinations and instrument references of one device.
---@param ctx ImportContext
---@param device renoise.AudioDevice
---@param data DeviceData
---@param own_source_track integer
---@param label string
local function remap_device(ctx, device, data, own_source_track, label)
  local names = data.param_names
  local values = data.param_values
  local source_master = ctx.export.master_index


  for _, param_index in ipairs(Routing.receiver_params(data.name, names)) do
    if ctx.plan.drop_sends[own_source_track] then
      device.is_active = false
      warn(ctx, '%s: send routing not imported, "%s" bypassed', label, data.display_name)
    else
      local source_send = Routing.send_track_index_from_value(values[param_index], source_master)
      local target = ctx.track_map[source_send]
      if target then
        set_param(device, param_index, Routing.value_from_send_track_index(target, ctx.target_master))
      else
        device.is_active = false
        warn(ctx, '%s: send target of "%s" not imported, device bypassed', label, data.display_name)
      end
    end
  end

  for _, destination in ipairs(Routing.track_destinations(data.name, names)) do
    local dest_source = Routing.track_index_from_value(values[destination.track])
    local is_own = dest_source == nil
    dest_source = dest_source or own_source_track
    local dest_target = ctx.track_map[dest_source]
    if is_own and Routing.is_sidechain_device(data.name) then -- luacheck: ignore 542
      -- No sidechain destination set (-1 = none): nothing to remap.
    elseif not dest_target then
      device.is_active = false
      warn(ctx, '%s: "%s" targets a track that was not imported, bypassed', label, data.display_name)
    else
      if not is_own then
        set_param(device, destination.track, Routing.value_from_track_index(dest_target))
      end
      -- Changing the track may reset effect/parameter selections, so both get restored afterwards.
      if destination.effect then
        local effect_value = values[destination.effect]
        local source_device = Routing.device_index_from_value(effect_value)
        if source_device and dest_source == source_master and source_device > 1 then
          local target_device = ctx.master_device_map[source_device]
          if target_device then
            effect_value = Routing.value_from_device_index(target_device)
          else
            device.is_active = false
            warn(ctx, '%s: "%s" targets a master FX that was not imported', label, data.display_name)
          end
        end
        set_param(device, destination.effect, effect_value)
      end
      if destination.parameter then
        set_param(device, destination.parameter, values[destination.parameter])
      end
    end
  end

  for _, param_index in ipairs(Routing.instrument_params(data.name, names)) do
    local source_instrument = Routing.instrument_index_from_value(values[param_index])
    if source_instrument then
      local target = ctx.instrument_map[source_instrument]
      if target then
        set_param(device, param_index, Routing.value_from_instrument_index(target))
      else
        warn(ctx, '%s: instrument of "%s" was not imported', label, data.display_name)
      end
    end
  end
end

---@param ctx ImportContext
local function import_master_devices(ctx)
  local master = ctx.song:track(ctx.target_master)
  ctx.master_device_map[1] = 1
  for _, source_index in ipairs(ctx.plan.master_devices) do
    insert_device(ctx, master, ctx.export.master_devices[source_index])
    ctx.master_device_map[source_index] = #master.devices
  end
end

---@param ctx ImportContext
local function remap_all_devices(ctx)
  for source_index, data in pairs(ctx.export.tracks) do
    local track = ctx.song:track(ctx.track_map[source_index])
    for _, device_data in ipairs(data.devices) do
      -- Track device chains are copied completely, so device indices are identical.
      remap_device(ctx, track:device(device_data.index), device_data, source_index, data.name)
    end
  end
  local master = ctx.song:track(ctx.target_master)
  for source_index, device_data in pairs(ctx.export.master_devices) do
    local device = master:device(ctx.master_device_map[source_index])
    remap_device(ctx, device, device_data, ctx.export.master_index, 'Master')
  end
end

---Restores FX chain routings and plugin aliases of one imported instrument.
---@param ctx ImportContext
---@param names string[] target track names
---@param instrument renoise.Instrument
---@param data InstrumentData
local function remap_instrument(ctx, names, instrument, data)
  for chain_index, route in ipairs(data.chain_routes) do
    local chain = instrument.sample_device_chains[chain_index]
    if route and chain then
      local target = ctx.track_map[route]
      local routing = target
        and Routing.chain_routing_from_track_index(target, chain.available_output_routings, names)
      if routing then
        chain.output_routing = routing
      else
        warn(ctx, 'Instrument "%s": FX chain "%s" routing could not be restored', data.name, chain.name)
      end
    end
  end

  -- ASSUMPTION: plugin alias/routing indices are 1-based song indices, 0 = none.
  local plugin = instrument.plugin_properties
  local source = data.plugin
  if source.alias_instrument_index > 0 then
    Util.try_set(plugin, 'alias_instrument_index', ctx.instrument_map[source.alias_instrument_index] or 0)
  end
  if source.alias_fx_track_index > 0 then
    local target_track = ctx.track_map[source.alias_fx_track_index]
    if target_track then
      local device_index = source.alias_fx_device_index
      if source.alias_fx_track_index == ctx.export.master_index then
        device_index = ctx.master_device_map[device_index] or 0
      end
      Util.try_set(plugin, 'alias_fx_track_index', target_track)
      Util.try_set(plugin, 'alias_fx_device_index', device_index)
    else
      warn(ctx, 'Instrument "%s": FX alias track was not imported', data.name)
    end
  end
  if source.midi_output_routing_index > 0 then
    Util.try_set(plugin, 'midi_output_routing_index', ctx.instrument_map[source.midi_output_routing_index] or 0)
  end
end

---@param ctx ImportContext
local function remap_instruments(ctx)
  local names = {}
  for index, track in ipairs(ctx.song.tracks) do
    names[index] = track.name
  end
  for source_index, data in pairs(ctx.export.instruments) do
    -- Empty instruments were not exported; they point to the separator instrument.
    if data.file then
      remap_instrument(ctx, names, ctx.song:instrument(ctx.instrument_map[source_index]), data)
    end
  end
end

---@param ctx ImportContext
---@param value integer
---@return integer
local function remap_instrument_value(ctx, value)
  if value == renoise.PatternLine.EMPTY_INSTRUMENT then
    return value
  end
  local target = ctx.instrument_map[value + 1]
  return target and target - 1 or renoise.PatternLine.EMPTY_INSTRUMENT
end

---@param ctx ImportContext
---@param pattern renoise.Pattern
---@param data PatternData
local function fill_pattern(ctx, pattern, data)
  pattern.number_of_lines = data.number_of_lines
  pattern.name = data.name
  for source_track, track_data in pairs(data.tracks) do
    ProcessSlicer.step()
    local target_track = ctx.track_map[source_track]
    local pattern_track = pattern:track(target_track)
    for line_index, line_data in pairs(track_data.lines) do
      local line = pattern_track:line(line_index)
      for column, note in pairs(line_data.notes) do
        local ok = pcall(function()
          local target = line:note_column(column)
          target.note_value = note.note
          target.instrument_value = remap_instrument_value(ctx, note.instrument)
          target.volume_string = note.volume
          target.panning_string = note.panning
          target.delay_value = note.delay
          target.effect_number_value = note.effect_number
          target.effect_amount_value = note.effect_amount
        end)
        if not ok then
          warn(ctx, 'Some note data of track "%s" could not be written', ctx.export.tracks[source_track].name)
        end
      end
      for column, effect in pairs(line_data.effects) do
        pcall(function()
          local target = line:effect_column(column)
          target.number_value = effect.number
          target.amount_value = effect.amount
        end)
      end
    end
    local track = ctx.song:track(target_track)
    for _, automation_data in ipairs(track_data.automation) do
      local ok = pcall(function()
        local param = track:device(automation_data.device):parameter(automation_data.param)
        local automation = pattern_track:create_automation(param)
        automation.playmode = automation_data.playmode
        automation.points = automation_data.points
      end)
      if not ok then
        warn(ctx, 'Some automation of track "%s" could not be restored', ctx.export.tracks[source_track].name)
      end
    end
  end
end

---Appends the merge song's sequence with new patterns (keeping its pattern lengths and pattern reuse).
---The appended part starts with a section named like the separator instrument.
---@param ctx ImportContext
---@return integer sequence_slots
---@return integer patterns
local function import_patterns(ctx)
  local sequencer = ctx.song.sequencer
  local pattern_map = {}
  local pattern_count = 0
  local first_sequence = #sequencer.pattern_sequence + 1
  for source_sequence, source_pattern in ipairs(ctx.export.sequence) do
    ProcessSlicer.step(('Importing song data: sequence %d / %d'):format(source_sequence, #ctx.export.sequence))
    local sequence_index = #sequencer.pattern_sequence + 1
    if pattern_map[source_pattern] then
      sequencer:insert_sequence_at(sequence_index, pattern_map[source_pattern])
    else
      local pattern_index = sequencer:insert_new_pattern_at(sequence_index)
      pattern_map[source_pattern] = pattern_index
      pattern_count = pattern_count + 1
      fill_pattern(ctx, ctx.song:pattern(pattern_index), ctx.export.patterns[source_pattern])
    end
    for source_track in pairs(ctx.export.slot_mutes[source_sequence] or {}) do
      sequencer:set_track_sequence_slot_is_muted(ctx.track_map[source_track], sequence_index, true)
    end
  end
  if #ctx.export.sequence > 0 then
    sequencer:set_sequence_is_start_of_section(first_sequence, true)
    sequencer:set_sequence_section_name(first_sequence, merge_label(ctx))
  end
  return #ctx.export.sequence, pattern_count
end

local TYPE_LABELS = {
  [renoise.Track.TRACK_TYPE_SEQUENCER] = 'track',
  [renoise.Track.TRACK_TYPE_GROUP] = 'group',
  [renoise.Track.TRACK_TYPE_SEND] = 'send',
}

---@class ImportReportEntry
---@field name string
---@field source integer source index (1-based)
---@field target integer target index (1-based)
---@field kind string|nil

---@class ImportReport
---@field warnings string[]
---@field tracks ImportReportEntry[] sequencer, group and send tracks in target order
---@field instruments ImportReportEntry[]
---@field master_devices ImportReportEntry[]
---@field sequence_slots integer 0 when no song data was imported
---@field patterns integer

---@param ctx ImportContext
---@return ImportReport
local function build_report(ctx)
  local report = {
    warnings = ctx.warnings,
    tracks = {},
    instruments = {},
    master_devices = {},
    sequence_slots = ctx.sequence_slots or 0,
    patterns = ctx.pattern_count or 0,
  }
  for source, data in pairs(ctx.export.tracks) do
    report.tracks[#report.tracks + 1] =
      { name = data.name, source = source, target = ctx.track_map[source], kind = TYPE_LABELS[data.type] }
  end
  table.sort(report.tracks, function(a, b)
    return a.target < b.target
  end)
  for _, source in ipairs(ctx.plan.instruments) do
    local data = ctx.export.instruments[source]
    local name = data.file and data.name or (data.name .. ' (empty, mapped to separator)')
    report.instruments[#report.instruments + 1] = { name = name, source = source, target = ctx.instrument_map[source] }
  end
  for _, source in ipairs(ctx.plan.master_devices) do
    local data = ctx.export.master_devices[source]
    local name = data.display_name ~= '' and data.display_name or data.name
    report.master_devices[#report.master_devices + 1] =
      { name = name, source = source, target = ctx.master_device_map[source] }
  end
  return report
end

---Imports the exported data into the current song.
---@param export ExportData
---@param plan MergePlan
---@return ImportReport
function M.import(export, plan)
  ---@type ImportContext
  local ctx = {
    song = renoise.song(),
    export = export,
    plan = plan,
    track_map = {},
    instrument_map = {},
    master_device_map = {},
    target_master = 0,
    warnings = {},
  }

  import_instruments(ctx)
  ProcessSlicer.step('Creating tracks')
  import_tracks(ctx)
  for source_index, data in pairs(export.tracks) do
    ProcessSlicer.step(('Configuring track "%s"'):format(data.name))
    configure_track(ctx, ctx.song:track(ctx.track_map[source_index]), data)
  end
  import_master_devices(ctx)
  remap_all_devices(ctx)
  remap_instruments(ctx)
  if export.patterns then
    ctx.sequence_slots, ctx.pattern_count = import_patterns(ctx)
  end

  if #plan.tracks > 0 then
    ctx.song.selected_track_index = ctx.track_map[plan.tracks[1]]
  end
  return build_report(ctx)
end

return M
