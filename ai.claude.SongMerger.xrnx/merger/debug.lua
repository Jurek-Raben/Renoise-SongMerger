-- Debug helpers to verify the ASSUMPTIONs in routing.lua inside Renoise.

local Routing = require('merger.routing')
local Util = require('merger.util')

local M = {}

-- Plugins often expose hundreds of parameters; only the first ones are printed.
local PLUGIN_PARAM_LIMIT = 16

---Prints all devices and parameters of the selected track, plus routing interpretation, to the console.
function M.dump_selected_track()
  local song = renoise.song()
  local track = song.selected_track
  Util.log(
    'Track %d "%s" (type %d), output "%s"',
    song.selected_track_index,
    track.name,
    track.type,
    track.output_routing
  )
  for device_index, device in ipairs(track.devices) do
    Util.log(
      '  Device %d: name "%s", display "%s", path "%s"',
      device_index,
      device.name,
      device.display_name,
      device.device_path
    )
    local names = {}
    local is_native = Routing.is_native_device(device.device_path)
    for param_index, param in ipairs(device.parameters) do
      names[param_index] = param.name
      if not is_native and param_index == PLUGIN_PARAM_LIMIT + 1 then
        Util.log('    ... %d more plugin parameters omitted', #device.parameters - PLUGIN_PARAM_LIMIT)
      end
      if is_native or param_index <= PLUGIN_PARAM_LIMIT then
        Util.log(
          '    %3d %-24s value %-10s (%s) min %s max %s',
          param_index,
          param.name,
          tostring(param.value),
          param.value_string,
          tostring(param.value_min),
          tostring(param.value_max)
        )
      end
    end
    for _, destination in ipairs(Routing.track_destinations(device.name, names)) do
      Util.log(
        '    -> meta destination: track param %d, effect param %s, parameter param %s',
        destination.track,
        tostring(destination.effect),
        tostring(destination.parameter)
      )
    end
    for _, param_index in ipairs(Routing.receiver_params(device.name, names)) do
      Util.log('    -> send receiver param %d', param_index)
    end
    for _, param_index in ipairs(Routing.instrument_params(device.name, names)) do
      Util.log('    -> instrument param %d', param_index)
    end
  end
  local instrument = song.selected_instrument
  Util.log('Selected instrument "%s"', instrument.name)
  for chain_index, chain in ipairs(instrument.sample_device_chains) do
    Util.log('  FX chain %d "%s" routing "%s"', chain_index, chain.name, chain.output_routing)
    for index, routing in ipairs(chain.available_output_routings) do
      Util.log('    available %d: %s', index, routing)
    end
  end
  renoise.app():show_status(Util.TOOL_NAME .. ': device dump written to the scripting console')
end

return M
