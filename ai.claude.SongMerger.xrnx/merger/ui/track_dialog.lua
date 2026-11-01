-- Dialog 1: choose the tracks of the merge song.
-- The group hierarchy is shown as a real tree: a canvas per row draws guide lines, track colors and
-- collapse/expand triangles. The list is virtualized (fixed number of row widgets, scrollbar + mouse wheel),
-- so it works for songs with any number of tracks.

local Selection = require('merger.selection')
local Util = require('merger.util')
local Widgets = require('merger.ui.widgets')

local M = {}

local VISIBLE_ROWS = 16
local ROW_HEIGHT = 20
local INDENT = 16
local WHEEL_STEP = 3

local WIDTHS = {
  check = 22,
  name = 210,
  output = 80,
  sends = 150,
  meta = 150,
  instruments = 230,
  keep = 56,
}

local EMPTY = '-'

-- Tree model ------------------------------------------------------------------------------------------------------

---Index of the leftmost track of a track/group span (Renoise places members left of their group track).
---@param info MergeSongInfo
---@param index integer
---@return integer
local function span_start(info, index)
  local start = index
  for _, member in ipairs(info.tracks[index].members) do
    start = math.min(start, span_start(info, member))
  end
  return start
end

---@param info MergeSongInfo
---@param indices integer[]
---@return integer[]
local function sorted_by_position(info, indices)
  local sorted = {}
  for _, index in ipairs(indices) do
    sorted[#sorted + 1] = index
  end
  table.sort(sorted, function(a, b)
    return span_start(info, a) < span_start(info, b)
  end)
  return sorted
end

---@param info MergeSongInfo
---@param index integer
---@param result integer[]|nil
---@return integer[]
local function descendants(info, index, result)
  result = result or {}
  for _, member in ipairs(info.tracks[index].members) do
    result[#result + 1] = member
    descendants(info, member, result)
  end
  return result
end

---@class TreeRow
---@field index integer
---@field depth integer
---@field is_last boolean
---@field lines table<integer, boolean> guide line columns that continue through this row
---@field has_children boolean

---Visible rows in tree order, skipping children of collapsed groups.
---@param info MergeSongInfo
---@param roots integer[]
---@param collapsed table<integer, boolean>
---@return TreeRow[]
local function visible_rows(info, roots, collapsed)
  local rows = {}
  local function visit(children, depth, lines)
    for position, index in ipairs(children) do
      local is_last = position == #children
      local members = info.tracks[index].members
      rows[#rows + 1] = {
        index = index,
        depth = depth,
        is_last = is_last,
        lines = lines,
        has_children = #members > 0,
      }
      if #members > 0 and not collapsed[index] then
        local child_lines = {}
        for column, value in pairs(lines) do
          child_lines[column] = value
        end
        if depth >= 1 then
          child_lines[depth] = not is_last
        end
        visit(sorted_by_position(info, members), depth + 1, child_lines)
      end
    end
  end
  visit(roots, 0, {})
  return rows
end

-- Drawing ---------------------------------------------------------------------------------------------------------

---@param context renoise.Views.Canvas.Context
---@param row TreeRow|nil
---@param track MergeTrackInfo|nil
---@param collapsed boolean
local function draw_guide(context, row, track, collapsed)
  if row == nil or track == nil then
    return
  end
  local mid = ROW_HEIGHT / 2
  local line_color = Widgets.theme_color('body_font', 90)
  context.stroke_color = line_color
  context.line_width = 1

  -- Guide lines of ancestors that continue below this row.
  for column = 1, row.depth - 1 do
    if row.lines[column] then
      local x = (column - 1) * INDENT + INDENT / 2
      context:begin_path()
      context:move_to(x, 0)
      context:line_to(x, ROW_HEIGHT)
      context:stroke()
    end
  end

  -- Elbow connecting this row to its parent.
  if row.depth >= 1 then
    local x = (row.depth - 1) * INDENT + INDENT / 2
    context:begin_path()
    context:move_to(x, 0)
    context:line_to(x, row.is_last and mid or ROW_HEIGHT)
    context:move_to(x, mid)
    context:line_to(row.depth * INDENT + 3, mid)
    context:stroke()
  end

  local center_x = row.depth * INDENT + INDENT / 2
  local color = { track.color[1], track.color[2], track.color[3], 255 }

  if track.type == 'group' then
    -- Line down to the first child when expanded.
    if row.has_children and not collapsed then
      context:begin_path()
      context:move_to(center_x, mid + 4)
      context:line_to(center_x, ROW_HEIGHT)
      context:stroke()
    end
    -- Expand/collapse triangle in the group's color.
    context.fill_color = color
    context.stroke_color = Widgets.theme_color('body_font', 160)
    context:begin_path()
    if collapsed then
      context:move_to(center_x - 3, mid - 5)
      context:line_to(center_x + 4, mid)
      context:line_to(center_x - 3, mid + 5)
    else
      context:move_to(center_x - 5, mid - 3)
      context:line_to(center_x + 5, mid - 3)
      context:line_to(center_x, mid + 4)
    end
    context:close_path()
    context:fill()
    context:stroke()
  else
    -- Track color swatch.
    context.fill_color = color
    context.stroke_color = Widgets.theme_color('body_font', 160)
    context:begin_path()
    context:rect(center_x - 4, mid - 4, 8, 8)
    context:fill()
    context:stroke()
  end
end

-- Text helpers ----------------------------------------------------------------------------------------------------

---@param info MergeSongInfo
---@param indices integer[]
---@return string
local function track_names(info, indices)
  local names = {}
  for _, index in ipairs(indices) do
    names[#names + 1] = info.tracks[index].name
  end
  return #names > 0 and table.concat(names, ', ') or EMPTY
end

---@param info MergeSongInfo
---@param track MergeTrackInfo
---@return string
local function meta_text(info, track)
  local parts = {}
  if #track.meta_out > 0 then
    parts[#parts + 1] = 'to ' .. track_names(info, track.meta_out)
  end
  if #track.meta_in > 0 then
    parts[#parts + 1] = 'from ' .. track_names(info, track.meta_in)
  end
  return #parts > 0 and table.concat(parts, '; ') or EMPTY
end

---@param info MergeSongInfo
---@param track MergeTrackInfo
---@return string
local function instrument_text(info, track)
  local entries = {}
  for _, index in ipairs(Util.sorted_keys(track.instruments)) do
    local instrument = info.instruments[index]
    local entry = ('%02X %s'):format(index - 1, instrument.name)
    if #instrument.route_tracks > 0 then
      entry = entry .. ' > ' .. track_names(info, instrument.route_tracks)
    end
    entries[#entries + 1] = entry
  end
  return #entries > 0 and table.concat(entries, ', ') or EMPTY
end

---@param text string
---@param width integer
---@return string
local function fit(text, width)
  return Util.ellipsize(text, math.floor(width / 6.5))
end

-- Dialog ----------------------------------------------------------------------------------------------------------

---Shows the track selection dialog.
---@param info MergeSongInfo
---@param choices MergeChoices
---@param on_next fun(choices: MergeChoices)
---@param on_cancel fun()
function M.show(info, choices, on_next, on_cancel)
  local vb = renoise.ViewBuilder()
  local close

  local roots, max_depth, groups = {}, 0, {}
  for _, track in ipairs(info.tracks) do
    if track.type == 'sequencer' or track.type == 'group' then
      max_depth = math.max(max_depth, track.depth)
      if track.parent == nil then
        roots[#roots + 1] = track.index
      end
      if track.type == 'group' then
        groups[#groups + 1] = track.index
      end
    end
  end
  roots = sorted_by_position(info, roots)
  local guide_width = (max_depth + 1) * INDENT + 4

  local collapsed = {}
  local rows = {}
  local offset = 0
  local updating = false
  local slots = {}
  local refresh

  local function set_selected(index, value)
    choices.selected[index] = value
    for _, child in ipairs(descendants(info, index)) do
      choices.selected[child] = value
    end
    refresh()
  end

  -- Row slots (reused while scrolling).
  local list = vb:column { spacing = 0 }
  for slot_index = 1, VISIBLE_ROWS do
    local slot = {}
    slot.guide = vb:canvas {
      width = guide_width,
      height = ROW_HEIGHT,
      mode = 'transparent',
      render = function(context)
        local row = slot.row
        draw_guide(context, row, row and info.tracks[row.index], row and collapsed[row.index] == true)
      end,
      mouse_events = { 'down' },
      mouse_handler = function(event)
        local row = slot.row
        if event.type == 'down' and row and row.has_children then
          collapsed[row.index] = not collapsed[row.index]
          refresh()
        end
        return nil
      end,
    }
    slot.check = vb:checkbox {
      width = WIDTHS.check,
      notifier = function(value)
        if not updating and slot.row then
          set_selected(slot.row.index, value)
        end
      end,
    }
    slot.name = vb:text { width = WIDTHS.name }
    slot.output = vb:text { width = WIDTHS.output }
    slot.sends = vb:text { width = WIDTHS.sends }
    slot.meta = vb:text { width = WIDTHS.meta }
    slot.instruments = vb:text { width = WIDTHS.instruments }
    slot.keep = vb:checkbox {
      notifier = function(value)
        if not updating and slot.row then
          choices.keep_sends[slot.row.index] = value
          refresh()
        end
      end,
    }
    slot.view = vb:row {
      height = ROW_HEIGHT,
      slot.guide,
      slot.check,
      slot.name,
      slot.output,
      slot.sends,
      slot.meta,
      slot.instruments,
      vb:horizontal_aligner { mode = 'center', width = WIDTHS.keep, slot.keep },
    }
    slots[slot_index] = slot
    list:add_child(slot.view)
  end

  local scrollbar = vb:scrollbar {
    min = 0,
    max = VISIBLE_ROWS,
    pagestep = VISIBLE_ROWS,
    step = 1,
    value = 0,
    width = 16,
    height = VISIBLE_ROWS * ROW_HEIGHT,
    autohide = false,
    notifier = function(value)
      if not updating then
        offset = value
        refresh()
      end
    end,
  }

  local function scroll(delta)
    offset = math.max(0, math.min(offset + delta, math.max(0, #rows - VISIBLE_ROWS)))
    refresh()
  end

  local list_frame = vb:row {
    background = 'border',
    margin = 2,
    mouse_events = { 'wheel' },
    mouse_handler = function(event)
      if event.type == 'wheel' then
        scroll(event.direction == 'up' and -WHEEL_STEP or WHEEL_STEP)
      end
      return nil
    end,
    list,
    scrollbar,
  }

  local function header_cell(text, width)
    return vb:text { text = text, width = width, font = 'bold', style = 'disabled' }
  end
  local column_header = vb:row {
    vb:space { width = guide_width + 4 },
    header_cell('', WIDTHS.check),
    header_cell('Track', WIDTHS.name),
    header_cell('Output', WIDTHS.output),
    header_cell('Sends to', WIDTHS.sends),
    header_cell('Meta routing', WIDTHS.meta),
    header_cell('Instruments', WIDTHS.instruments),
    header_cell('Keep sends', WIDTHS.keep),
  }

  -- Send tracks overview.
  local send_views = {}
  local send_column = vb:column { spacing = 2 }
  for _, track in ipairs(info.tracks) do
    if track.type == 'send' then
      local users = {}
      for _, other in ipairs(info.tracks) do
        for _, send in ipairs(other.sends) do
          if send == track.index then
            users[#users + 1] = other.index
          end
        end
      end
      local status = vb:text { width = 110 }
      send_views[track.index] = status
      send_column:add_child(vb:row {
        spacing = 6,
        Widgets.dot(vb, { track.color[1], track.color[2], track.color[3], 255 }, 10),
        vb:text { text = fit(track.name, 160), tooltip = track.name, width = 160, font = 'bold' },
        status,
        vb:text {
          text = fit('used by: ' .. track_names(info, users), 360),
          tooltip = 'used by: ' .. track_names(info, users),
          width = 360,
          style = 'disabled',
        },
        vb:text {
          text = fit('output: ' .. track.output_routing, 160),
          width = 160,
          style = 'disabled',
        },
      })
    end
  end
  if table.is_empty(send_views) then
    send_column:add_child(vb:text { text = 'The merge song has no send tracks.', style = 'disabled' })
  end

  local summary_text = vb:text { font = 'bold' }
  local selection_text = vb:text { style = 'disabled' }

  refresh = function()
    updating = true
    rows = visible_rows(info, roots, collapsed)
    offset = math.max(0, math.min(offset, math.max(0, #rows - VISIBLE_ROWS)))

    local plan = Selection.resolve(info, choices)
    local imported = {}
    for _, index in ipairs(plan.tracks) do
      imported[index] = true
    end
    for _, index in ipairs(plan.sends) do
      imported[index] = true
    end

    for slot_index, slot in ipairs(slots) do
      local row = rows[offset + slot_index]
      slot.row = row
      local track = row and info.tracks[row.index]
      slot.check.visible = track ~= nil
      slot.keep.visible = track ~= nil
      if track then
        local is_group = track.type == 'group'
        local label = track.name
        if is_group then
          local all = descendants(info, track.index)
          local selected = 0
          for _, child in ipairs(all) do
            if choices.selected[child] then
              selected = selected + 1
            end
          end
          label = ('%s   %d/%d'):format(track.name, selected, #all)
        end
        slot.check.value = choices.selected[track.index] == true
        slot.name.text = fit(label, WIDTHS.name)
        slot.name.tooltip = track.name
        slot.name.font = is_group and 'bold' or 'normal'
        -- Tracks that are not checked but get imported anyway (e.g. parent groups) are highlighted.
        slot.name.style = (imported[track.index] and not choices.selected[track.index]) and 'strong' or 'normal'
        slot.output.text = track.parent and 'Group' or fit(track.output_routing, WIDTHS.output)
        local keep = choices.keep_sends[track.index] ~= false
        slot.sends.text = fit(track_names(info, track.sends), WIDTHS.sends)
        slot.sends.tooltip = track_names(info, track.sends)
        slot.sends.style = (#track.sends > 0 and keep) and 'normal' or 'disabled'
        slot.meta.text = fit(meta_text(info, track), WIDTHS.meta)
        slot.meta.tooltip = meta_text(info, track)
        slot.instruments.text = fit(instrument_text(info, track), WIDTHS.instruments)
        slot.instruments.tooltip = instrument_text(info, track)
        slot.keep.value = keep
        slot.keep.active = #track.sends > 0
      else
        for _, view in ipairs({ slot.name, slot.output, slot.sends, slot.meta, slot.instruments }) do
          view.text = ''
          view.tooltip = ''
        end
      end
      slot.guide:update()
    end

    -- Widen the range first, so neither the old nor the new value is ever out of range.
    local new_max = math.max(#rows, VISIBLE_ROWS)
    scrollbar.max = math.max(scrollbar.max, new_max)
    scrollbar.value = offset
    scrollbar.max = new_max

    for index, status in pairs(send_views) do
      status.text = imported[index] and 'will be imported' or 'not imported'
      status.style = imported[index] and 'strong' or 'disabled'
    end

    local checked = 0
    for _, selected in pairs(choices.selected) do
      if selected then
        checked = checked + 1
      end
    end
    selection_text.text = ('%d of %d tracks/groups checked'):format(checked, table.count(choices.selected))
    summary_text.text = ('Will import %d tracks/groups, %d send tracks, %d instruments'):format(
      #plan.tracks,
      #plan.sends,
      #plan.instruments
    )
    updating = false
  end

  local function set_all(value)
    for index in pairs(choices.selected) do
      choices.selected[index] = value
    end
    refresh()
  end

  local function set_collapsed(value)
    for _, index in ipairs(groups) do
      collapsed[index] = value
    end
    offset = 0
    refresh()
  end

  local function cancel()
    close()
    on_cancel()
  end

  local function next_step()
    local plan = Selection.resolve(info, choices)
    if #plan.tracks == 0 and #info.master_devices == 0 then
      renoise.app():show_warning('Please select at least one track.')
      return
    end
    close()
    on_next(choices)
  end

  local small = 84
  local content = vb:column {
    margin = Widgets.MARGIN,
    spacing = Widgets.SPACING,
    Widgets.header(vb, 'Select tracks', 'Merge song: ' .. info.file_name),
    vb:row {
      spacing = 4,
      Widgets.button(vb, { text = 'Select all', width = small, notifier = function() set_all(true) end }),
      Widgets.button(vb, { text = 'Select none', width = small, notifier = function() set_all(false) end }),
      vb:space { width = 12 },
      Widgets.button(vb, { text = 'Expand all', width = small, notifier = function() set_collapsed(false) end }),
      Widgets.button(vb, { text = 'Collapse all', width = small, notifier = function() set_collapsed(true) end }),
      vb:space { width = 12 },
      vb:vertical_aligner { mode = 'center', height = Widgets.BUTTON_HEIGHT, selection_text },
    },
    vb:column {
      spacing = 2,
      column_header,
      list_frame,
    },
    vb:text {
      text = 'Click a triangle to collapse/expand a group. Checking a group checks all its children; children can be '
        .. 'unchecked individually. Highlighted names are imported automatically (parent groups).',
      style = 'disabled',
    },
    Widgets.section(vb, 'Send tracks', {
      send_column,
      vb:text {
        text = 'Send tracks are imported once when any imported track keeps its send routing.',
        style = 'disabled',
      },
    }, '100%'),
    Widgets.section(vb, 'Options', {
      vb:row {
        vb:checkbox {
          value = choices.import_patterns,
          notifier = function(value)
            choices.import_patterns = value
          end,
        },
        vb:text { text = 'Import song data', font = 'bold' },
        vb:text {
          text = '  patterns and automation are appended to the sequence, keeping their pattern lengths',
          style = 'disabled',
        },
      },
    }, '100%'),
    vb:horizontal_aligner {
      mode = 'justify',
      width = '100%',
      vb:vertical_aligner { mode = 'center', height = Widgets.BUTTON_HEIGHT, summary_text },
      vb:row {
        spacing = 6,
        Widgets.button(vb, { text = 'Cancel', notifier = cancel }),
        Widgets.button(vb, { text = 'Next >', kind = 'primary', notifier = next_step }),
      },
    },
  }

  refresh()
  close = Widgets.show_dialog('Tracks', content, { esc = cancel }, on_cancel)
end

return M
