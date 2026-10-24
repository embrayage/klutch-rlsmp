const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const assert = require('node:assert/strict')
const root = path.resolve(__dirname, '..')
const game = process.env.BEAMNG_DIR
if (!game) throw new Error('Set BEAMNG_DIR to the BeamNG installation directory')
const file = path.join(root, 'src/client/ui/ui-vue/mods/rlsmp_teamx/PlayerExchanges.vue')
const source = fs.readFileSync(file, 'utf8')
const vueContext = {console:{info(){},warn(){},error:console.error}}
vm.createContext(vueContext)
vm.runInContext(fs.readFileSync(path.join(game,'ui/lib/ext/vue3/vue.global.js'),'utf8'),vueContext)
const template = source.match(/<template>([\s\S]*?)<\/template>\s*<script/)[1]
const errors = []
vueContext.Vue.compile(template,{decodeEntities:x=>x,onError:error=>errors.push(error.message)})
assert.deepEqual(errors,[])
const manifest = JSON.parse(fs.readFileSync(path.join(root,'src/client/gameplay/overhaul/phone/apps/rlsmp-exchanges.json')))
assert.equal(manifest.component,'/ui/ui-vue/mods/rlsmp_teamx/PlayerExchanges.vue')
assert.equal(manifest.unlock.extension,'rlsmpTeamx')
assert.equal(manifest.unlock.function,'isTradingAvailable')
assert.equal(manifest.name,'Player Exchange')
for (const marker of ['RLS MULTIJOUEUR','\u00c9changes','Virement','Portefeuille','Sauvegarde','Choisir','Acheter']) {
  assert(!source.includes(marker),`exchange UI must be English: ${marker}`)
}
// Exercise RLS's real normalization and registry against the installed game's actual icons.
// The old manifest passed Lua discovery, but its nonexistent icon made the JS registry drop it.
const career = path.join(root,'reference/rls/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career')
const catalog = fs.readFileSync(path.join(career,'utils/phoneAppCatalog.js'),'utf8')
const registry = fs.readFileSync(path.join(career,'utils/phoneAppRegistry.js'),'utf8')
const iconContext = {createUnlockCondition:()=>()=>true, ADDON_ROUTE_PREFIX:'/overhaul/phone-app/'}
vm.createContext(iconContext)
vm.runInContext(fs.readFileSync(path.join(game,'ui/ui-vue/src/assets/fonts/bngIcons/bngIcons.js'),'utf8')
  .replace(/^export .*$/gm,'')+'\nglobalThis.iconSet=icons',iconContext)
for (const name of ['resolveIcon','normalizeManifest']) {
  vm.runInContext(catalog.match(new RegExp(`export function ${name}\\([\\s\\S]*?\\n}`))[0].replace('export ',''),iconContext)
}
vm.runInContext(catalog.match(/const PLATFORM_FIELDS = new Set\(.*\)/)[0],iconContext)
vm.runInContext(registry.match(/function isValidManifest\([\s\S]*?\n}/)[0],iconContext)
const normalized = iconContext.normalizeManifest(manifest)
assert(iconContext.isValidManifest(normalized),'the app must survive the native RLS phone registry')
assert.equal(normalized.icon,iconContext.iconSet.group)
assert.equal(normalized.route,'/overhaul/phone-app/rlsmp-exchanges')
assert(!iconContext.isValidManifest(iconContext.normalizeManifest({...manifest,icon:'people'})), 'reproduce the invisible 0.5.0 app')
console.log('PASS: actual BeamNG icons and RLS normalization/registry reproduce the missing app; corrected manifest stays visible')
const calls = [], hooks = {}
let returnError = false
const context = {
  ...Object.fromEntries(['ref','computed'].map(key=>[key,vueContext.Vue[key]])),
  defineProps:()=>({callLua:async (...args)=>{calls.push(args);return returnError ? {error:'Insufficient funds'} : {ok:true}}}),
  onMounted:fn=>hooks.mount=fn,onUnmounted:fn=>hooks.unmount=fn,
  setInterval:()=>1,clearInterval:()=>{},Intl,Number,Math,
}
vm.createContext(context)
vm.runInContext(source.match(/<script setup>([\s\S]*?)<\/script>/)[1].replace(/^import .*$/gm,'')+
  '\nglobalThis.ui={state,tab,target,vehicleId,amount,error,busy,confirm,review,confirmAction,execute,refresh,blocked,search,sort,filteredListings,currency}',context)
;(async () => {
  const ui=context.ui
  assert.equal(ui.tab.value,'marketplace')
  ui.tab.value='money'
  ui.state.value={active:true,enabled:true,wallet:500,players:[{id:0,name:'Premier joueur <b>'}],vehicles:[{id:3,name:'Voiture'}]}
  assert.equal(ui.target.value,-1)
  ui.target.value=0;ui.amount.value='150.50';ui.review()
  assert.equal(calls.length,0,'review cannot issue a transaction')
  assert.equal(ui.confirm.value.target,0,'BeamMP player ID zero is selectable')
  ui.amount.value='999';ui.target.value=5
  await ui.confirmAction()
  assert.equal(calls[0][1],'money');assert.equal(calls[0][2],0);assert.equal(calls[0][3],150.5)
  ui.state.value={active:true,enabled:true,players:[{id:0,name:'P0'}],vehicles:[{id:3,name:'Voiture'}]}
  ui.target.value=-1;ui.tab.value='sell';ui.vehicleId.value=3;ui.amount.value='3000';ui.review()
  assert.equal(ui.confirm.value.carName,'Voiture')
  await ui.confirmAction()
  const sale=calls.find(c=>c[1]==='publish');assert.equal(sale[4],3)
  ui.confirm.value={op:'buy',listing:{id:'1000-4',title:'Truck',cents:300000,seller:'Seller'}}
  await ui.confirmAction()
  assert(calls.some(c=>c[1]==='buy' && c[5]==='1000-4'))
  ui.confirm.value={op:'withdraw',listing:{id:'1000-5',title:'Own truck',cents:1000}}
  await ui.confirmAction()
  assert(calls.some(c=>c[1]==='withdraw' && c[5]==='1000-5'))
  ui.state.value={listings:[{id:'1',title:'Truck',model:'pickup',seller:'P1',cents:100,created:2},{id:'2',title:'Coupe',model:'bx',seller:'P2',cents:200,created:3}]}
  ui.search.value='pickup';assert.equal(ui.filteredListings.value.length,1)
  ui.search.value='';ui.sort.value='high';assert.equal(ui.filteredListings.value[0].id,'2')
  assert.equal(ui.currency(1234.5),'$1,234.50')
  ui.confirm.value={op:'accept',offer:{id:'1000-1',kind:'car',cents:300000,from:{name:'Vendeur'}}}
  await ui.confirmAction()
  assert(calls.some(c=>c[1]==='accept' && c[5]==='1000-1'))
  returnError=true;await ui.execute('money','',{target:0,amount:99})
  assert.equal(ui.error.value,'Insufficient funds')
  ui.busy.value=true;const count=calls.length;await ui.execute('money');assert.equal(calls.length,count)
  hooks.unmount()
  console.log('PASS: exchanges phone template, manifest, player ID zero, confirmation before sending, immutable reviewed values, car sale/acceptance, errors and double-click suppression')
})().catch(error=>{console.error(error);process.exitCode=1})
