// Run the real RLS loader with BeamNG's actual route-readiness implementation.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm')
const assert = require('node:assert/strict')
const root = path.resolve(__dirname, '..'), game = process.env.BEAMNG_DIR
if (!game) throw new Error('Set BEAMNG_DIR')
const member = 'ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils/runtimeComponent.js'
const manifest = JSON.parse(fs.readFileSync(path.join(root,'build/build-manifest.json'),'utf8'))
const loader = fs.readFileSync(path.join(root,manifest.patchedFiles[member] ? 'build/patched-lua' : 'reference/rls',member),'utf8')
const readiness = fs.readFileSync(path.join(game,'ui/ui-vue/src/services/routeReadiness.js'),'utf8')
const config = fs.readFileSync(path.join(game,'lua/ge/extensions/ui/router/config.lua'),'utf8')
const commitBudget = Number(config.match(/routeCommit\s*=\s*([\d.]+)/)[1]) * 1000
const mountBudget = Number(config.match(/mountReady\s*=\s*([\d.]+)/)[1]) * 1000
const picker = '/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/profiles/views/ProfileSelect.vue'
const actualProfile=fs.readFileSync(path.join(root,'reference/rls',picker.slice(1)),'utf8')
assert(!/\bbeforeRouteEnter\b/.test(actualProfile),'Recheck deferred profile admission if native entry guards are introduced')
const plain = s => s.replace(/^import .*$/gm,'').replace(/export /g,'')
;(async () => {
  let now=0, timerId=0, readyAcks=0, focuses=0
  const timers=new Map(), requests=new Map(), unmounts=[]
  const route={name:'overhaul.profiles',fullPath:'/overhaul/profiles',meta:{handlesOwnReady:true}}
  let handoff={id:1,transitionId:'profile-1',canonicalRoute:route.name}
  const ctx={Map,Set,Promise,Error,console,
    defineAsyncComponent:loader=>({__asyncLoader:loader}),markRaw:x=>x,defineComponent:x=>x,
    shallowRef:value=>({value}),h:(type,props,children)=>({type,props,children}),
    nextTick:()=>Promise.resolve(),getCurrentInstance:()=>({}),useRoute:()=>route,
    onUnmounted:fn=>unmounts.push(fn),watch:(read,fn,options)=>{if(options?.immediate)fn(read());return ()=>{}},
    activateRouteTargetScope:()=>{focuses++},reportUiFailure:()=>{},
    lua:{extensions:{ui_router:{routeMounted:async(name,tid)=>{
      assert.equal(name,route.name);assert.equal(tid,handoff.transitionId);readyAcks++;return {success:true}
    }}}},
    loadModule:file=>new Promise((resolve,reject)=>requests.set(file,{resolve,reject})),
    setTimeout:(fn,delay)=>{timers.set(++timerId,{fn,at:now+delay});return timerId},
    clearTimeout:id=>timers.delete(id),
    window:{__rtModules:{},__bngRuntime:{resolve:(_,file)=>file,invalidate:()=>{}},__luaRouter__:{
      getVueHandoff:()=>handoff,_clearVueHandoff:()=>{},getPendingTransitionId:()=>handoff.transitionId,
    }}}
  vm.createContext(ctx);vm.runInContext(plain(readiness)+'\n'+plain(loader),ctx)
  const flush=async()=>{for(let i=0;i<30;i++)await Promise.resolve()}
  const advance=async(ms)=>{
    const end=now+ms
    for(;;){
      const next=[...timers.entries()].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0]
      if(!next)break
      now=next[1].at;timers.delete(next[0]);next[1].fn();await flush()
    }
    now=end;await flush()
  }
  ctx.beginVueTransition(route,handoff)
  let presentation
  const pending=ctx.runtimeRouteComponent(picker,{phone:false})()
  pending.then(component=>{presentation=component})
  await flush();await advance(350)
  assert(presentation,'Cold career selector must present a loading screen before BeamNG cancels navigation')
  assert(now<commitBudget)
  const render=presentation.setup({}, {attrs:{scopeId:'career-profiles'}})
  const loading=render()
  assert.equal(loading.type,'div')
  assert(loading.children,'The loading presentation must be visible, not an empty world')
  await ctx.completeVueTransition(route,handoff,true,()=>true);await flush()
  assert.equal(readyAcks,1,'handlesOwnReady requires an explicit native readiness producer')
  assert.equal(focuses,1)
  await advance(commitBudget+mountBudget+1000)
  assert.equal(readyAcks,1)
  const realProfile={name:'RealCareerProfiles'}
  requests.get(picker).resolve({default:realProfile});await flush()
  assert.equal(render().type,realProfile)
  assert.equal(render().props.scopeId,'career-profiles')
  assert.equal(await pending,presentation,'Keep the mounted presentation stable after the cold import')

  // An import error leaves an actionable retry screen; retry uses a fresh native graph request.
  route.fullPath='/overhaul/profiles?retry=1';handoff={id:2,transitionId:'profile-2',canonicalRoute:route.name}
  ctx.beginVueTransition(route,handoff)
  const failedFile='/failed'+picker
  const failedPromise=ctx.runtimeRouteComponent(failedFile,{phone:false})()
  await flush();requests.get(failedFile).reject(new Error('simulated module failure'));await flush()
  const failed=await failedPromise
  const errorRender=failed.setup({}, {attrs:{}})
  await ctx.completeVueTransition(route,handoff,true,()=>true);await flush()
  assert.equal(readyAcks,2)
  const button=errorRender().children.find(node=>node.type==='button')
  assert(button,'A failed selector must offer an English retry button')
  button.props.onClick();await flush()
  requests.get(failedFile).resolve({default:realProfile});await flush()
  assert.equal(errorRender().type,realProfile)

  // A cancelled/unmounted selector must not acknowledge a later transition.
  route.fullPath='/overhaul/profiles?cancelled=1';handoff={id:3,transitionId:'profile-3',canonicalRoute:route.name}
  ctx.beginVueTransition(route,handoff)
  const cancelledFile='/cancelled'+picker
  const cancelled=ctx.runtimeRouteComponent(cancelledFile,{phone:false})()
  await flush();await advance(350)
  const abandoned=await cancelled
  abandoned.setup({}, {attrs:{}})
  for(const unmount of unmounts)unmount()
  ctx.cancelVueTransition(route,handoff)
  await flush();requests.get(cancelledFile).resolve({default:realProfile});await flush()
  assert.equal(readyAcks,2)
  console.log('PASS: cold profiles beat the native commit/mount deadlines, acknowledge real route readiness, render delayed imports, retry failures and cancel stale screens')
})().catch(error=>{console.error(error);process.exitCode=1})
