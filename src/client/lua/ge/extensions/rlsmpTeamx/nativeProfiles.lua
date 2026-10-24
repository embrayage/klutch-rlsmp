-- Adapt RLS's own profile screens to account-owned profiles on this server.
local soloSaves = require('rlsmpTeamx/soloSaves')
local M = {}

function M.new(context)
  local api = {}
  local hook, pendingNames, sources = nil, {}, {}
  local importing = false

  function api.isOwned(profile)
    local session = context.session()
    if not session or type(profile) ~= 'string' then return false end
    if profile == session.profile then return true end
    local prefix = session.profile .. '_'
    return profile:sub(1, #prefix) == prefix and profile:sub(#prefix + 1):match('^[a-z0-9_]+$') ~= nil
  end

  function api.allocate(name)
    if not context.authorized() or type(name) ~= 'string' then return nil end
    name = name:match('^%s*(.-)%s*$')
    if name == '' or #name > 100 then return nil end
    local slug = name:lower():gsub('[^a-z0-9]', ''):sub(1, 60)
    if slug == '' then slug = 'profile' end
    local base = context.session().profile .. '_' .. slug
    local root = overhaul_career_saveSystem.getSaveRootDirectory()
    for suffix = 0, 999 do
      local id = suffix == 0 and base or (base .. '_' .. suffix)
      if not FS:directoryExists(root .. id) then return id end
    end
  end

  function api.profileSelected(_, profile)
    if not api.isOwned(profile) then return end
    context.selected(profile)
    local name = pendingNames[profile]
    if name then
      overhaul_career_saveSystem.setRlsmpDisplayName(profile, name)
      pendingNames[profile] = nil
    end
  end

  function api.install()
    local career = overhaul_career_career
    if not career or not career.createOrLoadCareerAndStart then return false end
    if hook and career.createOrLoadCareerAndStart == hook.wrapper then return true end
    local original = career.createOrLoadCareerAndStart
    local wrapper = function(name, folder, options)
      if not context.multiplayer() then return original(name, folder, options) end
      if not context.authorized() then return false end
      local profile, displayName = name, nil
      if not api.isOwned(name) then
        profile, displayName = api.allocate(name), name
        if not profile then context.error('Career name is invalid or unavailable.'); return false end
        pendingNames[profile] = displayName
      end
      local settings = deepcopy(options or {})
      settings.startingMap = context.session().level
      local result = original(profile, folder, settings)
      if result ~= false then context.selected(profile) else pendingNames[profile] = nil end
      return result
    end
    hook = {owner = career, original = original, wrapper = wrapper}
    career.createOrLoadCareerAndStart = wrapper
    return true
  end

  function api.open()
    if not context.authorized() then return false end
    local saves = overhaul_career_saveSystem
    if not saves or saves.isSavePending() then return false end
    if overhaul_career_career.isActive() or overhaul_career_career.isStarting() then
      if not api.isOwned(saves.getCurrentProfile())
        or saves.getSaveRootDirectory() ~= 'settings/rlsmpTeamx/saves/' .. context.session().serverId .. '/' then
        return false
      end
    end
    if not overhaul_career_career.isActive() and not overhaul_career_career.isStarting() then
      saves.setProfile(nil)
      if not saves.setRlsmpNamespace(context.session().serverId) then return false end
    end
    if not api.install() then return false end
    local router = extensions and extensions.ui_router or ui_router
    if not router or not router.navigate then return false end
    local result = router.navigate('overhaul.profiles')
    if result == false or type(result) == 'table' and result.result == false then return false end
    return true
  end

  function api.cards()
    if not context.authorized() then return {} end
    local cards = {}
    sources = {}
    for _, item in ipairs(soloSaves.scan(context.session().level)) do
      sources[item.id] = item
      local ok, card = pcall(overhaul_career_career.formatImportSourceCard, item.id, item.snapshot)
      if not ok or type(card) ~= 'table' then card = {} end
      card.id = 'rlsmp-solo:' .. item.id
      card.displayName = item.name .. ' (' .. item.source .. ')'
      card.importSource, card.rlsmpSolo = true, item.id
      card.rlsmpCompatible, card.canImport = item.compatible, item.compatible
      card.importBlockReason = item.reason
      card.requiresMigration, card.outdatedVersion = false, false
      card.incompatibleVersion = not item.compatible
      cards[#cards + 1] = card
    end
    return cards
  end

  function api.highlights(id, limit)
    if not context.authorized() then return {} end
    local item = sources[id]
    if not item then return {} end
    return overhaul_career_career.getImportSourceHighlights(item.id, item.snapshot, limit or 5)
  end

  function api.importSolo(id)
    if not context.authorized() or importing or not sources[id] then return false end
    if overhaul_career_career.isActive() or overhaul_career_career.isStarting()
      or overhaul_career_saveSystem.isSavePending() then return false end
    local session, item = context.session(), sources[id]
    local profile = item.compatible and api.allocate(item.name)
    if not profile then context.error(item.reason or 'Import unavailable.'); return false end
    importing = true
    core_jobsystem.create(function(job)
      local ok, folder, problem = xpcall(function()
        return soloSaves.copy(id, session.serverId, profile, session.level, {
          isCurrent = function() return context.session() == session and context.authorized() end,
          yield = function() job.yield() end,
        })
      end, debug.traceback)
      if context.session() ~= session then return end
      importing = false
      if not ok or not folder then
        context.error(ok and problem or 'Import interrupted. Check beamng.log.')
        if not ok then log('E', 'rlsmpTeamx', tostring(folder)) end
        return
      end
      api.install()
      local didLoad, loaded = pcall(overhaul_career_career.createOrLoadCareerAndStart,
        profile, folder, {startingMap = session.level})
      if not didLoad then log('E', 'rlsmpTeamx', tostring(loaded)) end
      if not didLoad or loaded == false then context.error('The solo career copy was kept, but could not be loaded.') end
    end)
    return true
  end

  function api.restore()
    if hook and hook.owner.createOrLoadCareerAndStart == hook.wrapper then
      hook.owner.createOrLoadCareerAndStart = hook.original
    end
    hook, pendingNames, sources, importing = nil, {}, {}, false
  end

  function api.isImporting() return importing end
  return api
end

return M
