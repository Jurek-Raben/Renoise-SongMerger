-- Knowledge about routing parameters of send and meta devices.
-- All semantics that could not be verified in the API docs are marked with ASSUMPTION and kept in this file only,
-- so they can be adjusted in one place after testing in Renoise.

local M = {}

local SEND_DEVICE_NAMES = {
  ['#Send'] = true,
  ['#Multiband Send'] = true,
}

-- ASSUMPTION: native meta device names start with '*' (e.g. '*LFO', '*Hydra', '*Instr. Automation').
local META_PREFIX = '*'

-- ASSUMPTION: track destination parameters are named '... Track' (e.g. 'Dest. Track', 'Out1 Track') and have
-- matching '... Effect' and '... Parameter' siblings with the same prefix.
local TRACK_PARAM_PATTERN = 'Track$'

-- ASSUMPTION: send receiver parameters contain 'Receiver' (e.g. 'Receiver' or 'Receiver 1').
local RECEIVER_PARAM_PATTERN = 'Receiver'

-- ASSUMPTION: instrument destination parameters of '*Instr. ...' devices are named 'Instrument'.
local INSTRUMENT_DEVICE_PATTERN = '^%*Instr%.'
local INSTRUMENT_PARAM_PATTERN = '^Instrument$'

---@param device_name string
---@return boolean
function M.is_send_device(device_name)
  return SEND_DEVICE_NAMES[device_name] == true
end

---@param device_name string
---@return boolean
function M.is_meta_device(device_name)
  return device_name:sub(1, #META_PREFIX) == META_PREFIX
end

-- Verified via debug dump (Renoise 3.5): '#Sidechain' has the parameters 'Dest. Track' (0-based track index,
-- -1 = none) and 'Dest. Effect' (0-based device index incl. the mixer, -1 = none).
local SIDECHAIN_DEVICE_NAME = '#Sidechain'

---@param device_name string
---@return boolean
function M.is_sidechain_device(device_name)
  return device_name == SIDECHAIN_DEVICE_NAME
end

---@param device_path string
---@return boolean
function M.is_native_device(device_path)
  -- ASSUMPTION: native device paths look like 'Audio/Effects/Native/<Name>'.
  return device_path:find('/Native/', 1, true) ~= nil
end

---Returns the index of a parameter by name or nil.
---@param param_names string[]
---@param name string
---@return integer|nil
local function find_param(param_names, name)
  for index, param_name in ipairs(param_names) do
    if param_name == name then
      return index
    end
  end
  return nil
end

---Destination parameter groups of a meta or sidechain device.
---@param device_name string
---@param param_names string[]
---@return { track: integer, effect: integer|nil, parameter: integer|nil }[]
function M.track_destinations(device_name, param_names)
  local result = {}
  if not M.is_meta_device(device_name) and not M.is_sidechain_device(device_name) then
    return result
  end
  for index, name in ipairs(param_names) do
    if name:find(TRACK_PARAM_PATTERN) then
      result[#result + 1] = {
        track = index,
        effect = find_param(param_names, (name:gsub(TRACK_PARAM_PATTERN, 'Effect'))),
        parameter = find_param(param_names, (name:gsub(TRACK_PARAM_PATTERN, 'Parameter'))),
      }
    end
  end
  return result
end

---Receiver parameter indices of a send device.
---@param device_name string
---@param param_names string[]
---@return integer[]
function M.receiver_params(device_name, param_names)
  local result = {}
  if not M.is_send_device(device_name) then
    return result
  end
  for index, name in ipairs(param_names) do
    if name:find(RECEIVER_PARAM_PATTERN) then
      result[#result + 1] = index
    end
  end
  return result
end

---Instrument parameter indices of an instrument meta device.
---@param device_name string
---@param param_names string[]
---@return integer[]
function M.instrument_params(device_name, param_names)
  local result = {}
  if not device_name:find(INSTRUMENT_DEVICE_PATTERN) then
    return result
  end
  for index, name in ipairs(param_names) do
    if name:find(INSTRUMENT_PARAM_PATTERN) then
      result[#result + 1] = index
    end
  end
  return result
end

-- Value conversions. All indices on the Lua side are 1-based song indices.

---Track parameter value: 0-based index into song.tracks (verified for '#Sidechain' and meta devices).
----1 means "current track" for meta devices (ASSUMPTION) and "none" for '#Sidechain' (verified).
---@param value number
---@return integer|nil track_index nil for -1
function M.track_index_from_value(value)
  local rounded = math.floor(value + 0.5)
  if rounded < 0 then
    return nil
  end
  return rounded + 1
end

---@param track_index integer
---@return number
function M.value_from_track_index(track_index)
  return track_index - 1
end

---Effect parameter value -1 means "none", otherwise it is the 0-based index into track.devices including the
---mixer device at index 1 (verified for '#Sidechain' via Song.xml and debug dump).
---@param value number
---@return integer|nil
function M.device_index_from_value(value)
  local rounded = math.floor(value + 0.5)
  if rounded < 0 then
    return nil
  end
  return rounded + 1
end

---@param device_index integer
---@return number
function M.value_from_device_index(device_index)
  return device_index - 1
end

---ASSUMPTION: receiver value is the 0-based index of the send track (first send track = 0).
---@param value number
---@param master_index integer
---@return integer track_index
function M.send_track_index_from_value(value, master_index)
  return master_index + 1 + math.floor(value + 0.5)
end

---@param track_index integer
---@param master_index integer
---@return number
function M.value_from_send_track_index(track_index, master_index)
  return track_index - master_index - 1
end

---ASSUMPTION: instrument parameter value -1 means "none", otherwise it is the 0-based instrument index.
---@param value number
---@return integer|nil
function M.instrument_index_from_value(value)
  local rounded = math.floor(value + 0.5)
  if rounded < 0 then
    return nil
  end
  return rounded + 1
end

---@param instrument_index integer
---@return number
function M.value_from_instrument_index(instrument_index)
  return instrument_index - 1
end

---Resolves a sample device chain output routing string to a track index.
---ASSUMPTION: `available_output_routings` is { 'Current Track', <one entry per song track in track order> }.
---Falls back to a unique name match when the list size does not fit.
---@param routing string
---@param available string[]
---@param track_names string[]
---@return integer|nil track_index nil for "current track" or when unresolvable
---@return boolean resolved false when the routing could not be interpreted
function M.track_index_from_chain_routing(routing, available, track_names)
  local position = nil
  for index, name in ipairs(available) do
    if name == routing then
      position = index
      break
    end
  end
  if position == nil then
    return nil, false
  end
  if position == 1 then
    return nil, true
  end
  if #available == #track_names + 1 then
    return position - 1, true
  end
  local found = nil
  for index, name in ipairs(track_names) do
    if routing:find(name, 1, true) then
      if found then
        return nil, false
      end
      found = index
    end
  end
  return found, found ~= nil
end

---Inverse of `track_index_from_chain_routing` for the target song.
---@param track_index integer
---@param available string[]
---@param track_names string[]
---@return string|nil
function M.chain_routing_from_track_index(track_index, available, track_names)
  if #available == #track_names + 1 then
    return available[track_index + 1]
  end
  local found = nil
  for index = 2, #available do
    if available[index]:find(track_names[track_index], 1, true) then
      if found then
        return nil
      end
      found = available[index]
    end
  end
  return found
end

return M
