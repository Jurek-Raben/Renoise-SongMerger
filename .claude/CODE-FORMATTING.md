# Code Formatting

Formatting is derived from [.prettierrc.json](../.prettierrc.json). Prettier does not format Lua, so its settings are
translated into the following Lua rules. If TypeScript/JavaScript is ever added, Prettier applies to it directly.

## Mapping of .prettierrc.json to Lua

| Prettier setting          | Lua rule                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------- |
| `printWidth: 120`         | Max line length 120 characters.                                                       |
| `tabWidth: 2`             | Indent with 2 spaces.                                                                 |
| `useTabs: false`          | Never use tabs.                                                                       |
| `singleQuote: true`       | Use single quotes for strings (`'text'`); double quotes only to avoid escaping `'`.   |
| `semi: true`              | Not applicable to Lua: do **not** end statements with `;` (idiomatic Lua).            |
| `trailingComma: "es5"`    | Multiline table constructors get a trailing comma after the last entry.               |
| `importOrder: ["^[./]"]`  | `require` calls at the top of a file: Renoise/third-party first, then local modules.  |
| `importOrderSeparation`   | Separate those two `require` groups with one empty line.                              |
| `importOrderSortSpecifiers` | Sort `require` calls alphabetically within each group.                              |

## General Lua conventions

- `local` for every variable and function unless it must be global (only Renoise entry points).
- Naming: `snake_case` for variables and functions, `PascalCase` for class-like module tables,
  `UPPER_SNAKE_CASE` for constants.
- One module per file, returning a table: `local M = {} … return M`.
- Comments in English. LuaCATS annotations (`---@param`, `---@return`, `---@class`) for public functions.
- Wrap long function calls/tables like Prettier would: one argument/entry per line, closing bracket on its own line.

```lua
local Routing = require('merger.routing')

local MAX_SEND_TRACKS = 64

---Returns the new index of a send track after merging.
---@param send_map table<integer, integer>
---@param old_index integer
---@return integer|nil
local function remap_send(send_map, old_index)
  return send_map[old_index]
end

local options = {
  keep_sends = true,
  copy_instruments = true,
}
```
