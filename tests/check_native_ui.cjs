// Use the installed game's Vue template compiler and Node's parser, without dependencies.
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const vm = require('node:vm')
const cp = require('node:child_process')
const assert = require('node:assert/strict')
const root = path.resolve(__dirname, '..')
const game = process.argv[2] || process.env.BEAMNG_DIR
if (!game) throw new Error('Set BEAMNG_DIR to the BeamNG installation directory')
const base = path.join(root, 'build/patched-lua/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career')
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'build/build-manifest.json'), 'utf8'))
const relativeBase = 'ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/'
const read = file => fs.readFileSync(manifest.patchedFiles[relativeBase + file]
  ? path.join(base, file) : path.join(root, 'reference/rls', relativeBase, file), 'utf8')
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'rlsmp-ui-check-'))
try {
  for (const file of ['profiles/views/ProfileSelect.vue', 'stores/profilesStore.js',
      'profiles/components/start/useStartMaps.js', 'utils/installLuaBridgeFallbacks.js', 'utils/coreUiRoutes.js']) {
    const source = read(file)
    const script = file.endsWith('.vue') ? source.match(/<script setup>([\s\S]*?)<\/script>/)[1] : source
    const target = path.join(temp, path.basename(file) + '.mjs')
    fs.writeFileSync(target, script)
    cp.execFileSync('node', ['--check', target], {stdio:'pipe'})
  }
} finally {
  // Only the exact temporary directory created above is removed.
  assert.equal(path.dirname(path.resolve(temp)), path.resolve(os.tmpdir()))
  assert(path.basename(temp).startsWith('rlsmp-ui-check-'))
  fs.rmSync(temp, {recursive:true})
}
const vue = {console:{info(){},warn(){},error:console.error}}
vm.createContext(vue)
vm.runInContext(fs.readFileSync(path.join(game, 'ui/lib/ext/vue3/vue.global.js'),'utf8'),vue)
const profile = read('profiles/views/ProfileSelect.vue')
const template = profile.match(/<template>([\s\S]*?)<\/template>\s*<script/)[1]
const errors = []
vue.Vue.compile(template, {decodeEntities:raw=>raw, onError:error=>errors.push(error.message)})
assert.deepEqual(errors, [])
console.log('PASS: five native UI scripts parsed and profile template compiled with the installed Vue compiler')

// Exercise the actual fallback installer: an undeclared namespace otherwise silently hides the MP imports.
const fallbackSource = read('utils/installLuaBridgeFallbacks.js')
  .replace(/^import .*$/gm, '').replace(/export /g, '')
const calls = []
const lua = {}
const context = {luaImport:lua,onLuaNamespacesChanged:()=>{},window:{bngApi:{
  serializeToLua:value=>JSON.stringify(value),
  engineLua:(expr,resolve)=>{calls.push(expr);resolve({active:true})},
}}}
vm.createContext(context)
vm.runInContext(fallbackSource,context)
assert.equal(typeof lua.rlsmpTeamx.getUiContext, 'function')

;(async () => {
  assert.equal((await lua.rlsmpTeamx.getUiContext()).active,true)
  await lua.rlsmpTeamx.importSoloCareer('settings/cloud/overhaul/saves/solo')
  assert(calls[1].includes('"rlsmpTeamx"') && calls[1].includes('"importSoloCareer"'))
  assert(calls[1].includes('settings/cloud/overhaul/saves/solo'))
  let multiplayer = true
  const maps = {lua:{rlsmpTeamx:{getUiContext:async()=>({active:multiplayer,level:'rls_west_coast'})},
    overhaul_world_maps:{getMapCatalog:async()=>[
      {id:'italy',label:'Italy'},{id:'rls_west_coast',label:'RLS West Coast',defaultStart:true},
    ]}},ref:v=>({value:v}),shallowRef:v=>({value:v}),safeLua:()=>{},setTimeout,clearTimeout}
  vm.createContext(maps)
  vm.runInContext(read('profiles/components/start/useStartMaps.js')
    .replace(/^import .*$/gm,'').replace(/export /g,'')+'\nglobalThis.load=loadMapCatalog',maps)
  assert.equal((await maps.load()).length,1)
  assert.equal((await maps.load())[0].id,'rls_west_coast')
  multiplayer = false
  assert.equal((await maps.load()).length,2)
  console.log('PASS: native bridge namespace transports real calls; server map filtering and offline catalog restoration')
})().catch(error=>{console.error(error);process.exitCode=1})
