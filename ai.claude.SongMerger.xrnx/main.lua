-- Song Merger: merges selected tracks, sends, instruments and master FX of another song into the current song.

-- @build:skip-start
-- Makes Renoise reload the tool whenever one of its files changes (development only).
-- Removed from release packages by the GitHub workflow.
_AUTO_RELOAD_DEBUG = function()
end
-- @build:skip-end

local Controller = require('merger.controller')
local Debug = require('merger.debug')
local OptionsDialog = require('merger.ui.options_dialog')

renoise.tool():add_menu_entry {
  name = 'Main Menu:File:Merge Song...',
  invoke = Controller.start,
}

renoise.tool():add_menu_entry {
  name = 'Main Menu:Tools:Merge Song:Options...',
  invoke = OptionsDialog.show,
}

renoise.tool():add_menu_entry {
  name = 'Main Menu:Tools:Merge Song:Debug:Dump Devices of Selected Track',
  invoke = Debug.dump_selected_track,
}

renoise.tool():add_keybinding {
  name = 'Global:Tools:Song Merger - Merge Song...',
  invoke = function(repeated)
    if not repeated then
      Controller.start()
    end
  end,
}
