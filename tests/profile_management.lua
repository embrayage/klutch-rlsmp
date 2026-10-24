-- Run the actual patched native save-management functions on a virtual filesystem.
local saveRoot='server/'
local currentProfile,currentSavePath
local multiplayer=true
local active=false
local dirs, metadata = {}, {}
local function add(id)
  dirs[saveRoot..id]=true; dirs[saveRoot..id..'/autosave1']=true
  metadata[saveRoot..id..'/autosave1/info.json']={displayName=id}
end
add('beammp_12345'); add('beammp_12345_second'); add('beammp_67890'); add('offline')
local function owned(name)
  return name=='beammp_12345' or type(name)=='string' and name:match('^beammp_12345_[a-z0-9_]+$')~=nil
end
require=function() return {isMultiplayer=function() return multiplayer end,
  allowProfile=function(name) return not multiplayer or owned(name) end} end
rlsmpTeamx={allocateProfileName=function(name)
  if type(name)~='string' or name=='' then return nil end
  return 'beammp_12345_'..name:lower():gsub('[^a-z0-9]','')
end}
tableSize=function(t) return #t end
path={split=function(p) return p:match('^(.*)/([^/]+)$') end}
FS={
  directoryExists=function(_,p) return dirs[p]==true end,
  directoryList=function(_,p)
    local result={}
    local prefix=p:gsub('/+$','')..'/'
    for d in pairs(dirs) do
      if d:sub(1,#prefix)==prefix and not d:sub(#prefix+1):find('/',1,true) then result[#result+1]=d end
    end
    table.sort(result); return result
  end,
  findFiles=function(_,p)
    local result={}; for f in pairs(metadata) do if f:sub(1,#p)==p then result[#result+1]=f end end
    return result
  end,
  directoryRemove=function(_,p) dirs[p]=nil end,
}
isLegalDirectoryName=function(p) return type(p)=='string' and p:match('^[a-z0-9_]+$')~=nil end
jsonReadFile=function(p) return metadata[p] end
local writes=0
local function jsonWriteFileSafe(p,data) writes=writes+1; metadata[p]=data; return true end
local function setProfile(p) currentProfile=p end
local function renameFolder(source,target)
  local info=metadata[source..'/autosave1/info.json']
  dirs[source]=nil; dirs[source..'/autosave1']=nil; metadata[source..'/autosave1/info.json']=nil
  dirs[target]=true; dirs[target..'/autosave1']=true; metadata[target..'/autosave1/info.json']=info
  return true
end
local function copySlotFiles(source,target)
  add(target:sub(#saveRoot+1)); return true
end
local function isSavePending() return false end
overhaul_career_career={isActive=function() return active end}
local M={saveCurrent=function() end}
guihooks={trigger=function() end}
log=function() end

-- ACTUAL_FUNCTIONS

local listed=getAllProfiles()
assert(#listed==2 and listed[1]=='beammp_12345' and listed[2]=='beammp_12345_second')
assert(not renameProfile('beammp_67890','Foreign') and dirs['server/beammp_67890'])
assert(not duplicateSaveSlot('beammp_67890','Foreign'))
assert(not removeProfile('beammp_67890') and dirs['server/beammp_67890'])
assert(not removeSaveFolder('beammp_67890','autosave1') and dirs['server/beammp_67890/autosave1'])
assert(not updateProfileDisplayName('beammp_67890','Foreign') and writes==0)
assert(renameProfile('beammp_12345_second','New Name'))
assert(dirs['server/beammp_12345_newname'] and not dirs['server/beammp_12345_second'])
assert(metadata['server/beammp_12345_newname/autosave1/info.json'].displayName=='New Name')
assert(duplicateSaveSlot('beammp_12345','My Backup'))
assert(metadata['server/beammp_12345_mybackup/autosave1/info.json'].displayName=='My Backup')
assert(metadata['server/beammp_12345/autosave1/info.json'].displayName=='beammp_12345')
currentProfile='beammp_12345';currentSavePath='server/beammp_12345/autosave1';active=true
removeProfile('beammp_12345');assert(dirs['server/beammp_12345'])
assert(not removeSaveFolder('beammp_12345','autosave1'))
assert(not renameProfile('beammp_12345','Active'))
multiplayer=false
assert(#getAllProfiles()==5) -- stock solo listing keeps all local profiles
