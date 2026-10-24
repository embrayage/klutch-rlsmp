-- Read solo snapshots and copy the chosen snapshot into this account's MP profile.
-- A snapshot is visible to RLS only after info.json has been committed last.
local M = {}
local roots = {
  {path = 'settings/cloud/overhaul/saves', label = 'RLS single-player'},
  {path = 'settings/cloud/saves', label = 'BeamNG single-player'},
}
local candidates = {}
local sequence = 0

local function normalized(value)
  return tostring(value or ''):gsub('\\', '/'):gsub('^/+', ''):gsub('/+$', '')
end

local function below(value, parent)
  local child, base = normalized(value), normalized(parent) .. '/'
  if child:sub(1, #base) ~= base or child:find(':', 1, true) or child:find('%z') then return false end
  for part in child:gmatch('[^/]+') do
    if part == '.' or part == '..' then return false end
  end
  return true
end

-- Match native RLS commit ordering, including legacy slots and clock changes.
local function validSequence(info)
  local value = info.saveSequence
  if type(value) == 'number' and value >= 0 and value < math.huge and value % 1 == 0 then return value end
end
local function older(a, b)
  local left, right = validSequence(a), validSequence(b)
  if (left ~= nil) ~= (right ~= nil) then return left == nil end
  if left and right and left ~= right then return left < right end
  return a.date < b.date
end
local function newestHealthy(profilePath)
  local best, bestInfo
  for _, snapshot in ipairs(FS:directoryList(profilePath, false, true) or {}) do
    if below(snapshot, profilePath) and FS:directoryExists(snapshot) then
      local info = jsonReadFile(snapshot .. '/info.json')
      if type(info) == 'table' and not info.corrupted and type(info.date) == 'string'
        and (not bestInfo or older(bestInfo, info)) then
        best, bestInfo = normalized(snapshot), info
      end
    end
  end
  return best, bestInfo
end

local function refusal(snapshot, info, level)
  if type(info) ~= 'table' or info.corrupted or type(info.date) ~= 'string' then
    return 'This save is incomplete or unreadable.'
  end
  local version = tonumber(info.version)
  local currentVersion = overhaul_career_saveSystem.getSaveSystemVersion()
  if not version or version < currentVersion then
    return 'Open and save this career in single-player with the current RLS version before importing it.'
  end
  if version > currentVersion then return 'This save was created with a newer version.' end
  local migration = overhaul_career_saveMigration
  if migration and migration.requiresSaveMigration and migration.requiresSaveMigration(snapshot, info) then
    return 'Update this save in RLS single-player first.'
  end
  local general = jsonReadFile(snapshot .. '/career/general.json')
  if type(general) ~= 'table' or general.level ~= level then
    return 'This save is not on the server map.'
  end
end

function M.scan(level)
  candidates = {}
  local result = {}
  for _, source in ipairs(roots) do
    for _, profile in ipairs(FS:directoryList(source.path, false, true) or {}) do
      if below(profile, source.path) and FS:directoryExists(profile) then
        local snapshot, info = newestHealthy(profile)
        if snapshot then
          local id = normalized(profile)
          local item = {id = id, source = source.label, snapshot = snapshot,
            name = tostring(info.displayName or id:match('[^/]+$')),
            date = info.date, version = info.version, saveSequence = info.saveSequence, reason = refusal(snapshot, info, level)}
          item.compatible = item.reason == nil
          candidates[id] = item
          result[#result + 1] = item
        end
      end
    end
  end
  table.sort(result, function(a, b)
    if a.date ~= b.date then return a.date > b.date end
    return a.id < b.id
  end)
  return result
end

function M.copy(id, serverId, profile, level, options)
  options = options or {}
  local item = candidates[id]
  if not item or not item.compatible then return nil, 'Select a compatible single-player save.' end
  if type(serverId) ~= 'string' or #serverId ~= 32 or not serverId:match('^%x+$')
    or type(profile) ~= 'string' or not (profile:match('^beammp_%d+$') or profile:match('^beammp_%d+_[a-z0-9_]+$')) then
    return nil, 'Invalid save destination.'
  end
  local source = item.snapshot
  local info = jsonReadFile(source .. '/info.json')
  local blocked = refusal(source, info, level)
  if blocked then return nil, blocked end
  if info.date ~= item.date or info.version ~= item.version or info.saveSequence ~= item.saveSequence then
    return nil, 'The single-player save has changed. Refresh the list before trying again.'
  end
  local targetRoot = 'settings/rlsmpTeamx/saves/' .. serverId .. '/' .. profile
  local folder, destination
  repeat
    sequence = sequence + 1
    folder = 'import_solo_' .. tostring(os.time()) .. '_' .. tostring(sequence)
    destination = targetRoot .. '/' .. folder
  until not FS:directoryExists(destination)

  local function cancelled()
    return options.isCurrent and not options.isCurrent()
  end
  local function fail(message)
    -- Only this newly allocated snapshot can be removed. Never remove a profile
    -- or touch a source directory, including on copy failure or disconnect.
    if below(destination, targetRoot) and destination == targetRoot .. '/' .. folder then
      FS:directoryRemove(destination)
    end
    return nil, message
  end
  if cancelled() then return nil, 'Import cancelled: the session has changed.' end
  if FS:directoryCreate(destination, true) == false or not FS:directoryExists(destination) then
    return nil, 'Could not create the destination folder.'
  end
  local function copyFiles()
  local files = FS:findFiles(source, '*', -1, true, false) or {}
  local copied = 0
  for _, file in ipairs(files) do
    if not below(file, source) then return fail('Unexpected file path in the save.') end
    if not FS:directoryExists(file) then
      local relative = normalized(file):sub(#normalized(source) + 2)
      if relative ~= 'info.json' then
        if cancelled() then return fail('Import cancelled: the session has changed.') end
        local target = destination .. '/' .. relative
        local parent = target:match('^(.*)/[^/]+$')
        if not below(target, destination) then return fail('Invalid destination file path.') end
        FS:directoryCreate(parent, true)
        if FS:copyFile(file, target) ~= 0 then return fail('Copy failed. The original single-player save was kept.') end
        copied = copied + 1
        if options.yield and copied % 10 == 0 then options.yield() end
      end
    end
  end
  if copied == 0 or not FS:fileExists(destination .. '/career/general.json') then
    return fail('The save contains no readable career data.')
  end
  local latestInfo = jsonReadFile(source .. '/info.json')
  if cancelled() then return fail('Import cancelled: the session has changed.') end
  if type(latestInfo) ~= 'table' or latestInfo.corrupted or latestInfo.date ~= info.date
    or latestInfo.version ~= info.version or latestInfo.saveSequence ~= info.saveSequence then
    return fail('The single-player save changed while copying. Try again after it finishes saving.')
  end
  -- jsonReadFile returns a new table: only the copied snapshot gets a new date.
  info.rlsmpSoloImport = {source = item.source, profile = item.name, date = info.date}
  info.date = os.date('!%Y-%m-%dT%H:%M:%SZ')
  local ok, written = pcall(jsonWriteFile, destination .. '/info.json', info, true)
  local committed = ok and written ~= false and jsonReadFile(destination .. '/info.json')
  if type(committed) ~= 'table' or committed.date ~= info.date then
    return fail('Could not finish the import. The original single-player save was kept.')
  end
  return folder
  end
  local ok, result, problem = xpcall(copyFiles, debug.traceback)
  if not ok then
    log('E', 'rlsmpTeamx', tostring(result))
    return fail('Import interrupted. The original single-player save was kept.')
  end
  return result, problem
end

return M
