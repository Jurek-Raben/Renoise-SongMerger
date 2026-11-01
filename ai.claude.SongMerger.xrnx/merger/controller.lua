-- Merge workflow:
-- 1. Remember the target song (must be saved), ask for the merge song.
-- 2. Load the merge song, analyze it, show the track dialog and the master FX dialog.
-- 3. Export the selected data (plain Lua data + temp .xrni files).
-- 4. Reload the target song and import the data.

local Analyzer = require('merger.analyzer')
local ConfirmDialog = require('merger.ui.confirm_dialog')
local Exporter = require('merger.exporter')
local Importer = require('merger.importer')
local MasterDialog = require('merger.ui.master_dialog')
local ProcessSlicer = require('merger.process_slicer')
local Selection = require('merger.selection')
local SongLoader = require('merger.song_loader')
local StartDialog = require('merger.ui.start_dialog')
local SummaryDialog = require('merger.ui.summary_dialog')
local TrackDialog = require('merger.ui.track_dialog')
local Util = require('merger.util')

local M = {}

local state = nil

local show_tracks
local show_selection_end

local function remove_temp_files(export)
  if not export then
    return
  end
  for _, instrument in pairs(export.instruments) do
    if instrument.file then
      os.remove(instrument.file)
    end
  end
end

---Reloads the target song and optionally shows a message afterwards.
---@param message string|nil
local function return_to_target(message)
  local target = state.target_path
  state = nil
  SongLoader.load(target, function(ok, err)
    if not ok then
      renoise.app():show_warning(Util.TOOL_NAME .. ': ' .. err)
    elseif message then
      renoise.app():show_message(message)
    end
  end)
end

local function cancel()
  renoise.app():show_status(Util.TOOL_NAME .. ': cancelled, reloading the original song')
  return_to_target(nil)
end

---@param export ExportData
---@return { label: string, path: string }[]
local function temp_file_list(export)
  local files = {}
  for _, index in ipairs(Util.sorted_keys(export.instruments)) do
    local instrument = export.instruments[index]
    if instrument.file then
      files[#files + 1] = {
        label = ('Instrument %02X "%s"'):format(index - 1, instrument.name),
        path = instrument.file,
      }
    end
  end
  return files
end

---@param plan MergePlan
local function run_import(plan)
  local export = state.export
  local merge_path = state.info.file_name
  local target = state.target_path
  local started = state.started
  state = nil
  SongLoader.load(target, function(ok, err)
    if not ok then
      remove_temp_files(export)
      renoise.app():show_warning(Util.TOOL_NAME .. ': ' .. err)
      return
    end
    ProcessSlicer.run('Importing', false, Importer.import, function(imported, report)
      remove_temp_files(export)
      if not imported then
        renoise.app():show_warning(
          Util.TOOL_NAME .. ': import failed: ' .. tostring(report) .. '\nUse Undo to revert partial changes.'
        )
        return
      end
      SummaryDialog.show {
        merge_path = merge_path,
        target_path = target,
        report = report,
        auto_added = plan.auto_added,
        temp_files = temp_file_list(export),
        duration_s = os.difftime(os.time(), started),
      }
    end, export, plan)
  end)
end

---@param plan MergePlan
local function run_export(plan)
  ProcessSlicer.run('Exporting', true, Exporter.export, function(ok, result)
    if ok then
      state.export = result
      run_import(plan)
    elseif result == ProcessSlicer.CANCELLED then
      show_tracks()
    else
      return_to_target(Util.TOOL_NAME .. ': export failed: ' .. tostring(result))
    end
  end, state.info, plan)
end

---@param choices MergeChoices
local function merge(choices)
  local plan = Selection.resolve(state.info, choices)
  if #plan.tracks == 0 and #plan.master_devices == 0 then
    renoise.app():show_warning('Nothing selected.')
    show_tracks()
    return
  end
  ConfirmDialog.show(state.info, plan, function()
    run_export(plan)
  end, show_selection_end)
end

local function show_master()
  MasterDialog.show(state.info, state.choices, merge, show_tracks, cancel)
end

---Last selection dialog, used as "back" target of the confirmation dialog.
show_selection_end = function()
  if #state.info.master_devices > 0 then
    show_master()
  else
    show_tracks()
  end
end

show_tracks = function()
  TrackDialog.show(state.info, state.choices, function(choices)
    if #state.info.master_devices > 0 then
      show_master()
    else
      merge(choices)
    end
  end, cancel)
end

local function on_merge_song_loaded(ok, err)
  if not ok then
    -- Another song arrived (e.g. the user cancelled loading); the workflow is dropped.
    Util.log('Merge song not loaded: %s', tostring(err))
    state = nil
    return
  end
  ProcessSlicer.run('Analyzing', true, Analyzer.analyze, function(analyzed, info)
    if analyzed then
      state.info = info
      state.choices = Selection.default_choices(info)
      show_tracks()
    elseif info == ProcessSlicer.CANCELLED then
      cancel()
    else
      return_to_target(Util.TOOL_NAME .. ': analysis failed: ' .. tostring(info))
    end
  end)
end

---Entry point from the menu.
function M.start()
  if ProcessSlicer.is_running() then
    renoise.app():show_warning(Util.TOOL_NAME .. ': a merge is still in progress.')
    return
  end
  SongLoader.cancel()
  state = nil

  local target = renoise.song().file_name
  if target == '' then
    renoise.app():show_warning(Util.TOOL_NAME .. ': please save the current song first.')
    return
  end

  local path = renoise.app():prompt_for_filename_to_read({ 'xrns' }, 'Select the song to merge into the current song')
  if path == '' then
    return
  end
  if Util.normalize_path(path) == Util.normalize_path(target) then
    renoise.app():show_warning(Util.TOOL_NAME .. ': the merge song must differ from the current song.')
    return
  end

  StartDialog.show(target, path, function()
    state = { target_path = target, started = os.time() }
    SongLoader.load(path, on_merge_song_loaded)
  end, function() end)
end

return M
