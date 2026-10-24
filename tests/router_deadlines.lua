-- Use the installed BeamNG transition manager and timeout configuration.
Engine={generateUUID=function() return 'test-router' end}
log=function() end
local manager=dofile(GAME_LUA..'/ge/extensions/ui/router/managers/transitionManager.lua')
local config=require('ge/extensions/ui/router/config')
local function begin()
  local ok,id=manager.start({toRoute={name='overhaul.profiles'},session={
    routeName='overhaul.profiles',phase='startup',phaseElapsed=0,totalElapsed=0,
    timeSinceLastEmit=0,handoffAttempts=1,expectsMountAck=true,progress={},
  }})
  assert(ok)
  assert(manager.markProgress('overhaul.profiles','routeChangeReceived',id).success)
  assert(manager.markProgress('overhaul.profiles','routeNavigationStarted',id).success)
  assert(not manager.update(0))
  return id
end
local id=begin()
local cancelled=manager.update(config.PhaseTimeouts.routeCommit+0.01)
assert(cancelled and cancelled.type=='timeout' and cancelled.classification=='route_change_not_completed')
manager.cancel(cancelled.reason)
id=begin()
assert(0.3<config.PhaseTimeouts.routeCommit)
assert(not manager.update(0.3))
assert(manager.markCommitted('overhaul.profiles',id).success)
assert(not manager.update(0))
assert(not manager.update(0.016))
assert(manager.markMounted('overhaul.profiles',id).success)
assert(manager.complete('overhaul.profiles',id))
assert(not manager.update(30))
print('PASS: real BeamNG cancels the uncommitted cold route at its native deadline; early commit plus explicit mount readiness completes safely')
