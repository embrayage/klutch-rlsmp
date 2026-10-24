// Exercise the final release's native route loaders without retaining the older MP override.
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const assert = require('node:assert/strict')
const root = path.resolve(__dirname, '..')
const relative = 'ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/utils'
const read = (base, name) => fs.readFileSync(path.join(root, base, relative, name), 'utf8')
const plain = source => source.replace(/^import .*$/gm, '').replace(/export /g, '')
const picker = '/ui/ui-vue/mods/rls_career_overhaul/overhaul/modules/career/profiles/views/ProfileSelect.vue'
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'build/build-manifest.json'), 'utf8'))
assert.equal(manifest.patchedFiles[relative + '/coreUiRoutes.js'], undefined)
assert.equal(fs.existsSync(path.join(root, 'build/patched-lua', relative, 'coreUiRoutes.js')), false)
const routeSource = read('reference/rls', 'coreUiRoutes.js')
const snapshot = vm.runInNewContext('(' + read('reference/rls', 'builtinCoreUi.js').replace('export default', '') + ')')
const flatten = routes => routes.flatMap(route => [route, ...flatten(route.children || [])])
const descriptors = {snapshot, routeProps:new Proxy({}, {get:() => () => {}}),
  runtimeComponent:file => ({kind:'async-wrapper', file}),
  runtimeRouteComponent:(file, options) => ({kind:'route-loader', file, options}),
  runtimeHostComponent:file => ({kind:'host-loader', file})}
vm.createContext(descriptors)
vm.runInContext(plain(routeSource), descriptors)
const nativeRoutes = flatten(descriptors.buildCoreRoutes())
const pickerDescription = nativeRoutes.find(route => route.component?.file === picker)
assert.equal(pickerDescription.component.kind, 'route-loader')
assert.equal(pickerDescription.component.options.phone, false)
assert(nativeRoutes.some(route => route.component?.kind === 'host-loader'))

;(async () => {
  const timers = new Map(), requests = new Map(), invalidated = []
  let timerId = 0
  const flush = async () => { for (let i = 0; i < 14; i++) await Promise.resolve() }
  const context = {Map, Promise, Error, snapshot,
    defineAsyncComponent:loader => ({__asyncLoader:loader}), markRaw:value => value,
    defineComponent:options => options, shallowRef:value => ({value}),
    h:(type, props, children) => ({type, props, children}), onUnmounted:() => {}, reportUiFailure:() => {},
    loadModule:file => new Promise((resolve,reject) => requests.set(file, {resolve,reject})),
    setTimeout:(fn, delay) => {timers.set(++timerId, {fn, delay});return timerId},
    clearTimeout:id => timers.delete(id), routeProps:new Proxy({}, {get:() => () => {}}),
    window:{__rtModules:{},__bngRuntime:{resolve:(_,file) => file,invalidate:file => invalidated.push(file)}}}
  vm.createContext(context)
  vm.runInContext(plain(read('build/patched-lua', 'runtimeComponent.js')) + '\n' + plain(routeSource), context)
  const route = flatten(context.buildCoreRoutes()).find(route => route.name === pickerDescription.name)
  assert.equal(typeof route.component, 'function')
  assert.equal(typeof context.runtimeComponent(picker), 'object') // overlays retain their async wrappers
  let guarded = 0, committed = false
  const loaded = {name:'ActualProfileSelect',beforeRouteEnter:(to,from,next) => {guarded++;next()}}
  const pending = route.component().then(component => {committed=true;return component})
  await flush()
  assert.equal(committed, false)
  requests.get(picker).resolve({default:loaded})
  assert.equal(await pending, loaded)
  assert.equal(guarded, 0) // the real guard is returned for Vue Router's own injection context
  loaded.beforeRouteEnter({}, {}, () => {})
  assert.equal(guarded, 1)
  assert.equal(timers.size, 0)

  // Release behavior: slow cold routes wait instead of committing an empty 300ms presentation.
  const slowFile = '/slow/ProfileSelect.vue'
  const slowLoader = context.runtimeRouteComponent(slowFile, {phone:false})
  const slow = slowLoader()
  assert.equal(slowLoader(), slow)
  await flush()
  assert([...timers.values()].every(timer => timer.delay === 20000))
  let slowCommitted = false
  slow.then(() => {slowCommitted=true})
  await flush()
  assert.equal(slowCommitted, false)
  requests.get(slowFile).resolve({default:loaded})
  assert.equal(await slow, loaded)
  assert.equal(await slowLoader(), loaded)

  // A timed-out cold selector can recover in the stable native route presentation.
  const timeoutFile = '/timeout/ProfileSelect.vue'
  const timeout = context.runtimeRouteComponent(timeoutFile, {phone:false})()
  await flush()
  assert.equal(timers.size, 1)
  ;[...timers.values()][0].fn()
  const fallback = await timeout
  assert.equal(fallback.name, 'RoutePendingScreen')
  assert(invalidated.includes(timeoutFile))
  const render = fallback.setup({}, {attrs:{test:true}})
  assert.equal(render().type, 'div')
  await flush()
  requests.get(timeoutFile).resolve({default:loaded})
  await flush()
  assert.equal(render().type, loaded)
  fallback.beforeRouteEnter({}, {}, () => {})
  assert.equal(guarded, 2)

  // Phone failure retains the native visible retry screen.
  const phoneFile = '/phone/Screen.vue'
  const phone = context.runtimeRouteComponent(phoneFile, {phone:true})()
  await flush()
  requests.get(phoneFile).reject(new Error('simulated cold graph failure'))
  assert.equal((await phone).name, 'PhonePendingScreen')
  console.log('PASS: release-native selector routes await cold imports, retain real navigation guards and component identity, recover after timeouts, and preserve phone error screens')
})().catch(error => {console.error(error);process.exitCode = 1})
