-- Virtual filesystem checks: these tests never write actual player saves.
local function clone(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = clone(item) end
  return result
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
local function norm(path) return path:gsub('\\','/'):gsub('^/+',''):gsub('/+$','') end
local files, dirs, copies, commits = {}, {}, {}, {}
local failCopy, throwCopy, failCommit, changeSource
local function mkdir(path)
  path=norm(path); dirs[path]=true
  local parent=path:match('^(.*)/[^/]+$')
  if parent then mkdir(parent) end
end
local function put(path, data)
  files[norm(path)]=clone(data)
  mkdir(norm(path):match('^(.*)/[^/]+$'))
end
FS={
  directoryExists=function(_,path) return dirs[norm(path)]==true end,
  fileExists=function(_,path) return files[norm(path)]~=nil end,
  directoryCreate=function(_,path) mkdir(path); return true end,
  directoryList=function(_,path)
    local result, prefix={},norm(path)..'/'
    for entry in pairs(dirs) do
      if entry:sub(1,#prefix)==prefix and not entry:sub(#prefix+1):find('/',1,true) then
        result[#result+1]='/'..entry -- engine paths may start with a slash
      end
    end
    table.sort(result); return result
  end,
  findFiles=function(_,path)
    local result,prefix={},norm(path)..'/'
    for file in pairs(files) do if file:sub(1,#prefix)==prefix then result[#result+1]=file end end
    table.sort(result); return result
  end,
  copyFile=function(_,source,target)
    copies[#copies+1]={source=norm(source),target=norm(target)}
    if throwCopy and #copies==throwCopy then error('simulated disk exception') end
    if failCopy and #copies==failCopy then return -1 end
    assert(files[norm(source)]~=nil and files[norm(target)]==nil)
    put(target,files[norm(source)])
    if changeSource then files[changeSource].date='2026-11-01T00:00:00Z' end
    return 0
  end,
  directoryRemove=function(_,path)
    path=norm(path)
    assert(path:match('^settings/rlsmpTeamx/saves/%x+/beammp_%d+[a-z0-9_]*/import_solo_%d+_%d+$'),path)
    for file in pairs(files) do if file:sub(1,#path+1)==path..'/' then files[file]=nil end end
    for dir in pairs(dirs) do if dir==path or dir:sub(1,#path+1)==path..'/' then dirs[dir]=nil end end
    return true
  end,
}
jsonReadFile=function(path) return clone(files[norm(path)]) end
jsonWriteFile=function(path,data)
  commits[#commits+1]={path=norm(path),data=clone(data),copies=#copies}
  if failCommit then return false end
  assert(files[norm(path)]==nil)
  put(path,data); return true
end
log=function() end
overhaul_career_saveSystem={getSaveSystemVersion=function() return 64 end}
overhaul_career_saveMigration={requiresSaveMigration=function(_,info) return info.migration==true end}
local rls='settings/cloud/overhaul/saves/'
local vanilla='settings/cloud/saves/'
local function snapshot(root,profile,slot,date,version,level,extra)
  local base=root..profile..'/'..slot
  local info={version=version,date=date,displayName='Career '..profile}
  for k,v in pairs(extra or {}) do info[k]=v end
  put(base..'/info.json',info)
  put(base..'/career/general.json',{level=level})
  put(base..'/career/playerAttributes.json',{money={value=12345}})
  put(base..'/career/vehicles/1.json',{id=1,model='pickup'})
  put(base..'/career/vehicles/1.jpg','thumbnail bytes')
  return base
end
local alpha=snapshot(rls,'alpha','autosave1','2026-10-01T00:00:00Z',64,'west_coast_usa')
snapshot(rls,'alpha','autosave2','2026-10-02T00:00:00Z',64,'west_coast_usa',{corrupted=true})
snapshot(rls,'old','autosave1','2026-10-03T00:00:00Z',63,'west_coast_usa')
snapshot(rls,'future','autosave1','2026-10-04T00:00:00Z',65,'west_coast_usa')
snapshot(rls,'italy','autosave1','2026-10-05T00:00:00Z',64,'italy')
snapshot(rls,'layout','autosave1','2026-10-06T00:00:00Z',64,'west_coast_usa',{migration=true})
snapshot(vanilla,'alpha','autosave1','2026-10-07T00:00:00Z',64,'west_coast_usa')
local original=clone(files)
local solo=require('rlsmpTeamx/soloSaves')
local list=solo.scan('west_coast_usa')
assert(#list==6)
local byId={}
for _,item in ipairs(list) do byId[item.id]=item end
assert(byId[rls..'alpha'].snapshot==alpha)
assert(byId[rls..'alpha'].compatible and byId[vanilla..'alpha'].compatible)
for _,name in ipairs({'old','future','italy','layout'}) do assert(not byId[rls..name].compatible) end
local id=string.rep('a',32)
local destination='settings/rlsmpTeamx/saves/'..id..'/beammp_12345/'
put(destination..'autosave1/info.json',{sentinel='existing MP career'})
local function sameSources()
  for path,value in pairs(original) do assert(equal(files[path],value),path) end
end
local folder,problem=solo.copy(rls..'alpha',id,'beammp_12345','west_coast_usa')
assert(folder,problem)
assert(files[destination..folder..'/career/vehicles/1.jpg']=='thumbnail bytes')
assert(files[destination..folder..'/career/playerAttributes.json'].money.value==12345)
assert(files[destination..folder..'/info.json'].rlsmpSoloImport.date=='2026-10-01T00:00:00Z')
assert(files[destination..'autosave1/info.json'].sentinel=='existing MP career')
assert(#commits==1 and commits[1].copies==4 and commits[1].path==destination..folder..'/info.json')
sameSources()
local namedFolder=solo.copy(rls..'alpha',id,'beammp_12345_second','west_coast_usa')
assert(namedFolder)
assert(files['settings/rlsmpTeamx/saves/'..id..'/beammp_12345_second/'..namedFolder..'/info.json'])
assert(files[destination..'autosave1/info.json'].sentinel=='existing MP career')
assert(not solo.copy(rls..'alpha',id,'beammp_12345_../other','west_coast_usa'))

local function destinationState()
  local result={}
  for path,value in pairs(files) do if path:sub(1,#destination)==destination then result[path]=clone(value) end end
  return result
end
local previous=destinationState()
for _,mode in ipairs({'copyError','exception','commitError'}) do
  copies={}; commits={}; failCopy=nil; throwCopy=nil; failCommit=nil
  if mode=='copyError' then failCopy=2 elseif mode=='exception' then throwCopy=2 else failCommit=true end
  local result=solo.copy(rls..'alpha',id,'beammp_12345','west_coast_usa')
  assert(result==nil and equal(destinationState(),previous),mode)
  sameSources()
end
failCopy=nil; throwCopy=nil; failCommit=nil; copies={}; commits={}
assert(not solo.copy('../../outside',id,'beammp_12345','west_coast_usa'))
assert(not solo.copy(rls..'alpha','../escape','beammp_12345','west_coast_usa'))
assert(not solo.copy(rls..'alpha',id,'../victim','west_coast_usa'))
assert(not solo.copy(rls..'old',id,'beammp_12345','west_coast_usa'))
assert(#copies==0 and #commits==0)

for i=1,12 do put(alpha..'/career/extra/'..i..'.json',{index=i}) end
local current=true
local cancelled=solo.copy(rls..'alpha',id,'beammp_12345','west_coast_usa',{
  isCurrent=function() return current end,
  yield=function() current=false end,
})
assert(not cancelled and equal(destinationState(),previous))
copies={}; commits={}; changeSource=alpha..'/info.json'
assert(not solo.copy(rls..'alpha',id,'beammp_12345','west_coast_usa'))
assert(equal(destinationState(),previous))
files[alpha..'/info.json']=clone(original[alpha..'/info.json']); changeSource=nil
sameSources()

-- BETA commit sequences beat timestamps, including a clock going backwards.
local seq1=snapshot(rls,'betaSequence','autosave1','2026-10-22T10:00:00Z',64,'west_coast_usa',{saveSequence=10})
local seq2=snapshot(rls,'betaSequence','autosave2','2026-10-22T09:00:00Z',64,'west_coast_usa',{saveSequence=11})
local function selectedSnapshot()
  for _,item in ipairs(solo.scan('west_coast_usa')) do
    if item.id==rls..'betaSequence' then return item.snapshot end
  end
end
assert(selectedSnapshot()==seq2)
files[seq1..'/info.json'].date=files[seq2..'/info.json'].date
assert(selectedSnapshot()==seq2)
files[seq2..'/info.json'].saveSequence=12
assert(not solo.copy(rls..'betaSequence',id,'beammp_12345','west_coast_usa'))
assert(selectedSnapshot()==seq2)
local betaFolder=solo.copy(rls..'betaSequence',id,'beammp_12345','west_coast_usa')
assert(betaFolder and files[destination..betaFolder..'/info.json'].saveSequence==12)
print('PASS: BETA import chooses the latest commit across equal dates and clock changes; stale sequences are refused')

-- Final release: any sequenced commit is newer than a legacy slot, even after a clock change.
local legacy=snapshot(rls,'mixedRelease','autosave1','2030-01-01T00:00:00Z',64,'west_coast_usa')
local sequenced=snapshot(rls,'mixedRelease','autosave4','2026-10-24T00:00:00Z',64,'west_coast_usa',{saveSequence=0})
local mixed
for _,item in ipairs(solo.scan('west_coast_usa')) do if item.id==rls..'mixedRelease' then mixed=item end end
assert(mixed and mixed.snapshot==sequenced)
local imported=solo.copy(rls..'mixedRelease',id,'beammp_12345','west_coast_usa')
assert(imported and files[destination..imported..'/info.json'].saveSequence==0)
print('PASS: final-release imports prioritize sequenced commits over legacy slots and recognize autosave4')
