-- Final dialog after a merge: overview, details per imported item, warnings and optional debug info.

local Preferences = require('merger.preferences')
local Widgets = require('merger.ui.widgets')

local M = {}

---@class MergeSummary
---@field merge_path string
---@field target_path string
---@field report ImportReport
---@field auto_added string[]
---@field temp_files { label: string, path: string }[]
---@field duration_s number whole seconds

local DETAILS_WIDTH = 680
local DETAILS_HEIGHT = 320

---@param lines string[]
---@param title string
---@param entries string[]
local function add_section(lines, title, entries)
  lines[#lines + 1] = ('%s (%d)'):format(title, #entries)
  if #entries == 0 then
    lines[#lines + 1] = '  -'
  end
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = '  ' .. entry
  end
  lines[#lines + 1] = ''
end

---@param summary MergeSummary
---@return string[]
local function detail_lines(summary)
  local report = summary.report
  local lines = {}

  local tracks, sends = {}, {}
  for _, entry in ipairs(report.tracks) do
    local line = ('%-6s %-28s merge #%02d -> current #%02d'):format(entry.kind, entry.name, entry.source, entry.target)
    if entry.kind == 'send' then
      sends[#sends + 1] = line
    else
      tracks[#tracks + 1] = line
    end
  end
  add_section(lines, 'TRACKS AND GROUPS', tracks)
  add_section(lines, 'SEND TRACKS', sends)

  local instruments = {}
  for _, entry in ipairs(report.instruments) do
    instruments[#instruments + 1] =
      ('%-35s merge %02X -> current %02X'):format(entry.name, entry.source - 1, entry.target - 1)
  end
  add_section(lines, 'INSTRUMENTS', instruments)

  local master = {}
  for _, entry in ipairs(report.master_devices) do
    master[#master + 1] = ('%-35s merge #%02d -> current #%02d'):format(entry.name, entry.source, entry.target)
  end
  add_section(lines, 'MASTER FX', master)

  add_section(lines, 'ADDED AUTOMATICALLY', summary.auto_added)
  add_section(lines, 'WARNINGS', report.warnings)

  if Preferences.show_debug_info() then
    local files = {}
    for _, file in ipairs(summary.temp_files) do
      local state = io.exists(file.path) and 'still present' or 'deleted'
      files[#files + 1] = ('%s (%s)'):format(file.label, state)
      files[#files + 1] = '    ' .. file.path
    end
    lines[#lines + 1] = '--- DEBUG INFO ---'
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('TEMPORARY FILES (%d)'):format(#summary.temp_files)
    if #files == 0 then
      lines[#lines + 1] = '  -'
    end
    for _, entry in ipairs(files) do
      lines[#lines + 1] = '  ' .. entry
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = ('Duration: %d s'):format(summary.duration_s)
  end
  return lines
end

---Shows the summary dialog.
---@param summary MergeSummary
function M.show(summary)
  local report = summary.report
  local vb = renoise.ViewBuilder()
  local close

  local track_count, send_count = 0, 0
  for _, entry in ipairs(report.tracks) do
    if entry.kind == 'send' then
      send_count = send_count + 1
    else
      track_count = track_count + 1
    end
  end
  local song_data = 'not imported'
  if report.sequence_slots > 0 then
    song_data = ('%d sequence slots, %d new patterns'):format(report.sequence_slots, report.patterns)
  end

  local has_warnings = #report.warnings > 0
  local status_color = has_warnings and { 220, 150, 40, 255 } or { 70, 170, 90, 255 }
  local status_text = has_warnings and ('Merge finished with %d warning(s)'):format(#report.warnings)
    or 'Merge finished successfully'

  local function ok()
    close()
  end

  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    vb:row {
      spacing = 8,
      vb:vertical_aligner { mode = 'center', height = 28, Widgets.dot(vb, status_color, 16) },
      Widgets.header(vb, status_text, 'Save the song to keep the result.'),
    },
    vb:row {
      spacing = Widgets.SPACING,
      Widgets.section(vb, 'Songs', {
        Widgets.info_row(vb, 'Merged song', Widgets.basename(summary.merge_path), { font = 'bold', label_width = 90 }),
        vb:text { text = summary.merge_path, style = 'disabled' },
        Widgets.info_row(vb, 'Into', Widgets.basename(summary.target_path), { font = 'bold', label_width = 90 }),
        vb:text { text = summary.target_path, style = 'disabled' },
        Widgets.info_row(vb, 'Song data', song_data, { label_width = 90 }),
      }, (DETAILS_WIDTH - Widgets.SPACING) / 2),
      Widgets.section(vb, 'Imported', {
        Widgets.info_row(vb, 'Tracks/groups', tostring(track_count), { font = 'bold', label_width = 100 }),
        Widgets.info_row(vb, 'Send tracks', tostring(send_count), { font = 'bold', label_width = 100 }),
        Widgets.info_row(vb, 'Instruments', tostring(#report.instruments), { font = 'bold', label_width = 100 }),
        Widgets.info_row(vb, 'Master FX', tostring(#report.master_devices), { font = 'bold', label_width = 100 }),
        Widgets.info_row(
          vb,
          'Warnings',
          tostring(#report.warnings),
          { font = 'bold', label_width = 100, style = has_warnings and 'strong' or 'normal' }
        ),
      }, (DETAILS_WIDTH - Widgets.SPACING) / 2),
    },
    Widgets.section(vb, 'Details', {
      vb:multiline_text {
        text = table.concat(detail_lines(summary), '\n'),
        font = 'mono',
        width = DETAILS_WIDTH - 12,
        height = DETAILS_HEIGHT,
      },
    }, DETAILS_WIDTH),
    Widgets.footer(vb, {
      Widgets.button(vb, { text = 'OK', kind = 'primary', notifier = ok }),
    }),
  }

  close = Widgets.show_dialog('Summary', content, { ['return'] = ok, esc = ok })
end

return M
