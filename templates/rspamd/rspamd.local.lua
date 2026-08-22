-- rspamd.local.lua — ilexa's custom Lua rules entry point (loaded by the
-- stock rules/rspamd.lua when present). Keep each rule in its own file under
-- /etc/rspamd/lua.d/ and load it here; every load is guarded so one broken
-- rule file cannot take mail scanning down with it.

local rspamd_util   = require "rspamd_util"
local rspamd_logger = require "rspamd_logger"

local lua_d = '/etc/rspamd/lua.d'

for _, rule in ipairs({ 'brand_guard.lua' }) do
  local path = lua_d .. '/' .. rule
  if rspamd_util.file_exists(path) then
    local ok, err = pcall(dofile, path)
    if not ok then
      rspamd_logger.errx(rspamd_config, 'rspamd.local.lua: %s failed: %s', path, err)
    end
  end
end
