-- Run native BeamNG loading, fade and pause audio code with a simulated local player.
local globals, writes, logs, replies = {}, {}, {}, {}
local ready, authorized, owned, paused, engineLoading = false, true, true, false, true
local profile, route, playerId, level = 'beammp_12345_first', 'overhaul.profiles', 100, 'rls_west_coast'
local objects = {[100]={queueLuaCommand=function() error('Audio recovery must not rebuild vehicle sources') end}}
local selectedValues={master=0.43,engine=0.72,music=0.1}
local vehicleState={fuel=31,odometer=9876,damage=0.4,ignition=3}
log=function(_,tag,text) logs[#logs+1]=tag..':'..text end
SFXSystem={setGlobalParameter=function(key,value) globals[key]=value;writes[#writes+1]={key,value} end}
Engine={getStartingArgs=function() return {} end}
GFXDevice={devicePresent=function() return false end}
tableFindKey=function() end
tableIsEmpty=function(t) return not t or next(t)==nil end
table.clear=function(t) for k in pairs(t) do t[k]=nil end end
getMissionFilename=function() return '/levels/rls_west_coast/info.json' end
getCurrentLevelIdentifier=function() return level end
getObjectByID=function(id) return objects[id] end
be={getPlayerVehicleID=function() return playerId end}
simTimeAuthority={getPause=function() return paused end}
LoadingManager={isLoadingInProgress=function() return engineLoading end}
guihooks={trigger=function() end}
local callbacks={}
extensions={hook=function() end,ui_router={getState=function() return {currentRoute={request={name=route}}} end}}
core_vehicleBridge={requestValue=function(object,reply,key) assert(key=='ping');replies[#replies+1]=reply end}
core_gamestate=dofile(GAME_LUA..'/ge/extensions/core/gamestate.lua')
ui_fadeScreen=dofile(GAME_LUA..'/ge/extensions/ui/fadeScreen.lua')
core_audio=dofile(GAME_LUA..'/ge/extensions/core/audio.lua')
vec3=function() return {} end
settings={getValue=function() return 1 end}
core_sounds=dofile(GAME_LUA..'/ge/extensions/core/sounds.lua')
local function upvalue(fn,key)
  for i=1,30 do local name,value=debug.getupvalue(fn,i);if name==key then return value end;if not name then break end end
end
local function countCompleted()
  local count=0;for _,s in ipairs(logs) do if s:find('Global audio reset completed after career load',1,true) then count=count+1 end end;return count
end
local audio=require('rlsmpTeamx/audioRecovery').new({authorized=function() return authorized end,
  profile=function() return profile end,owned=function() return owned end,ready=function() return ready end})
local function ticks(n) for _=1,n do audio.update(0.25) end end
-- Native loading exit requests alone don't clear g_GameLoading: the UI acknowledgement does.
core_gamestate.requestEnterLoadingScreen('careerActivate')
assert(globals.g_GameLoading==1)
core_audio.onPhysicsPaused();core_sounds.setAudioBlur(1)
assert(globals.g_GamePause==1 and upvalue(core_sounds.setAudioBlur,'gameAudioBlurValue')==1)
ticks(20);assert(countCompleted()==0 and #replies==0) -- no reset before selection/activation
assert(audio.activate() and not audio.activate())
ticks(8);assert(audio.status().phase=='waitingForCareer')
ready=true;ticks(8);assert(audio.status().phase=='waitingForLoading')
engineLoading=false;ticks(8);assert(audio.status().phase=='waitingForLoading')
core_gamestate.requestExitLoadingScreen('careerActivate')
assert(not core_gamestate.loading() and globals.g_GameLoading==1) -- missing UI completion reproduced
route='play';paused=true;ticks(8);assert(audio.status().phase=='waitingForPause')
paused=false;route='phone-main';ticks(8);assert(audio.status().phase=='waitingForPlay')
route='play';owned=false;ticks(8);assert(audio.status().phase=='waitingForPlayer')
owned=true;ui_fadeScreen.start(0.2)
ui_fadeScreen.onScreenFadeStateDelayed(1)
for _=1,5 do ui_fadeScreen.onGuiUpdate() end
assert(ui_fadeScreen.isBlack());ticks(8);assert(audio.status().phase=='waitingForFade')
ui_fadeScreen.stop(0.2)
-- Recreate stale audio flags after a legitimate fade has completed.
SFXSystem.setGlobalParameter('g_GameLoading',1)
core_audio.onPhysicsPaused();core_sounds.setAudioBlur(1)
ticks(1);assert(#replies==1 and countCompleted()==0)
replies[1]({result={ping=true}});ticks(3);assert(countCompleted()==0)
ticks(1);assert(countCompleted()==1 and audio.status().phase=='complete')
assert(globals.g_GameLoading==0 and globals.g_GamePause==0 and globals.g_FadeTimeMS==1000)
assert(upvalue(core_sounds.setAudioBlur,'gameAudioBlurValue')==0)
assert(selectedValues.master==0.43 and selectedValues.engine==0.72 and selectedValues.music==0.1)
assert(vehicleState.fuel==31 and vehicleState.odometer==9876 and vehicleState.damage==0.4 and vehicleState.ignition==3)
local writeCount=#writes
assert(not audio.activate());ticks(40);assert(#writes==writeCount) -- no recurring audio resets
core_gamestate.requestEnterLoadingScreen('nextAssignment');core_audio.onPhysicsPaused()
local duringLoading=#writes;ticks(20);assert(#writes==duringLoading and globals.g_GameLoading==1 and globals.g_GamePause==1)
core_gamestate.requestExitLoadingScreen('nextAssignment')
-- Cancellation and reconnect, with stale asynchronous replies after teardown or a profile change.
for _,kind in ipairs({'stop','profile','disconnect'}) do
  audio.stop();authorized=true;owned=true;paused=false;profile='beammp_12345_first'
  assert(audio.activate());ticks(1);local oldReply=replies[#replies]
  if kind=='stop' then audio.stop() elseif kind=='profile' then profile='beammp_12345_other' else authorized=false end
  local count=countCompleted();oldReply({result={ping=true}});ticks(8);assert(countCompleted()==count,kind)
end
-- A walking character changing into a restored car must be stable and acknowledge anew.
audio.stop();authorized=true;profile='beammp_12345_other';assert(audio.activate());ticks(1)
local walkingReply=replies[#replies]
playerId=101;objects[101]={queueLuaCommand=objects[100].queueLuaCommand};ticks(1)
local carReply=replies[#replies];local count=countCompleted()
walkingReply({result={ping=true}});ticks(4);assert(countCompleted()==count)
carReply({result={ping=true}});ticks(4);assert(countCompleted()==count+1)
-- Missing replies are bounded, and delayed replies after a retry cannot complete that retry.
audio.stop();assert(audio.activate());ticks(1);local lostReply=replies[#replies]
ticks(20);assert(audio.status().pending)
local retryReply=replies[#replies];assert(retryReply~=lostReply)
count=countCompleted();lostReply({result={ping=true}});ticks(4);assert(countCompleted()==count)
retryReply({result={ping=true}});ticks(4);assert(countCompleted()==count+1)
audio.stop();assert(audio.activate());ticks(65);assert(audio.status().phase=='failed' and not audio.status().pending)
print('PASS: global loading/pause/blur recovery using native game audio code; activation/world/player readiness, legitimate loading/fade/pause guards, walking/car handoff, one-time execution and stale-reply cancellation')
