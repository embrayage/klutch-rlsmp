<template>
  <main class="exchanges">
    <header><span class="eyebrow">RLS MULTIPLAYER</span><h1>Player Exchange</h1><p>Wallet <strong>{{ currency(state.wallet) }}</strong></p></header>
    <nav aria-label="Player Exchange"><button v-for="item in tabs" :key="item.id" :class="{selected: tab === item.id}" @click="tab = item.id">{{ item.label }}<span v-if="item.id === 'offers' && incoming.length"> ({{ incoming.length }})</span></button></nav>
    <p v-if="error || state.error" class="notice error" role="alert">{{ error || state.error }}</p>
    <p v-if="state.saving" class="notice" role="status">Saving your exchange. Stay stopped until the save finishes.</p>
    <p v-if="!state.active || !state.enabled" class="notice">Waiting for the server and your RLS career.</p>
    <section v-if="pending.length" class="notice"><strong>Exchange in progress</strong><p v-for="tx in pending" :key="tx.id">{{ tx.waitingForOther ? 'Waiting for the other player' : tx.state === 'commit' ? 'Completing transaction' : tx.state === 'abort' ? 'Returning reserved funds' : 'Reserving funds' }} | {{ tx.profile }}</p><small>After reconnecting, load the same career to finish a pending exchange.</small></section>
    <section v-if="tab === 'marketplace'">
      <div class="section-title"><h2>Player Marketplace</h2><span>{{ listings.length }} listed</span></div>
      <p class="hint">Cars stay listed until their seller withdraws them or another player buys them. You can buy from an offline seller.</p>
      <label class="search">Search cars or sellers<input v-model="search" type="search" placeholder="Model, car name or seller" /></label>
      <label>Sort by<select v-model="sort"><option value="newest">Newest first</option><option value="low">Price: low to high</option><option value="high">Price: high to low</option></select></label>
      <p v-if="!filteredListings.length" class="hint">{{ listings.length ? 'No listings match your search.' : 'No cars listed yet. Open Sell to publish the first one.' }}</p>
      <div class="market-grid"><article v-for="listing in filteredListings" :key="listing.id" class="listing">
        <div class="car-mark" aria-hidden="true"><svg viewBox="0 0 120 44"><path d="M12 29l8-5 12-16h47l15 16 15 5v8H12zM38 13L28 25h55L74 13z" fill="currentColor"/><circle cx="32" cy="36" r="7" fill="#14232c"/><circle cx="91" cy="36" r="7" fill="#14232c"/></svg><span>{{ listing.model }}</span></div>
        <div class="listing-body"><small>{{ listing.year || 'Player-owned vehicle' }}</small><h3>{{ listing.title }}</h3><strong class="price">{{ currency(listing.cents / 100) }}</strong><p class="seller">{{ listing.seller }} <span :class="['badge', {online: listing.online}]">{{ listing.online ? 'Online' : 'Offline' }}</span></p><p v-if="listing.state === 'reserved'" class="hint">Purchase in progress</p>
        <button v-if="!listing.own" class="primary" :disabled="blocked || listing.state !== 'active'" @click="confirm = {op:'buy', listing}">Buy vehicle</button><button v-else :disabled="busy" @click="tab = 'sell'">Your listing</button></div>
      </article></div>
    </section>
    <section v-if="tab === 'sell' || tab === 'money'">
      <h2>{{ tab === 'money' ? 'Send money' : 'List your car' }}</h2>
      <p class="hint">{{ tab === 'money' ? 'The recipient accepts the transfer in Offers. Funds come from your RLS wallet.' : 'Store and repair your car first. Listed cars are reserved in your garage until sold or withdrawn.' }}</p>
      <form @submit.prevent="review">
        <template v-if="tab === 'money'"><label>Player<select v-model.number="target" required :disabled="blocked"><option :value="-1" disabled>Select a player</option><option v-for="player in players" :key="player.id" :value="player.id">{{ player.name }}</option></select></label><p v-if="!players.length" class="hint">No other player has loaded a career yet.</p></template>
        <template v-else><label>Car in your garage<select v-model.number="vehicleId" required :disabled="blocked"><option :value="0" disabled>Select a car</option><option v-for="car in vehicles" :key="car.id" :value="car.id">{{ car.name }}</option></select></label><p v-if="!vehicles.length" class="hint">No stored cars are currently available to list.</p></template>
        <label>{{ tab === 'money' ? 'Amount' : 'Asking price' }}<input v-model="amount" inputmode="decimal" type="number" min="0.01" max="100000000" step="0.01" required :disabled="blocked" /></label>
        <button type="submit" class="primary" :disabled="blocked || (tab === 'money' ? !selectedPlayer : !selectedCar)">{{ tab === 'money' ? 'Review transfer' : 'Review listing' }}</button>
      </form>
      <template v-if="tab === 'sell'"><h2>My listings</h2><p v-if="!myListings.length" class="hint">You have no active listings.</p><article v-for="listing in myListings" :key="listing.id"><h3>{{ listing.title }}</h3><strong class="price">{{ currency(listing.cents / 100) }}</strong><p class="hint">{{ listing.state === 'publishing' ? 'Publishing after your save' : listing.state === 'withdrawing' ? 'Withdrawal awaiting your save' : listing.state === 'reserved' ? 'Purchase in progress' : 'Listed until sold or withdrawn' }}</p><p v-if="listing.profile !== state.profile" class="hint">Load {{ listing.profile }} to manage this car.</p><button :disabled="blocked || listing.state === 'reserved' || listing.state === 'withdrawing' || listing.profile !== state.profile" @click="confirm = {op:'withdraw', listing}">Withdraw listing</button></article></template>
    </section>
    <section v-if="tab === 'offers'">
      <h2>Received offers</h2><p v-if="!incoming.length" class="hint">No offers received.</p>
      <article v-for="offer in incoming" :key="offer.id"><small>From {{ offer.from.name }}</small><h3>{{ offer.kind === 'money' ? 'Incoming money transfer' : offer.title }}</h3><strong class="price">{{ currency(offer.cents / 100) }}</strong><p>{{ offer.kind === 'money' ? 'This amount will be added to your wallet.' : 'This legacy private offer will charge your wallet and deliver the car to your garage.' }}</p><div class="actions"><button class="primary" :disabled="blocked" @click="confirm = {op:'accept', offer}">Review offer</button><button :disabled="busy" @click="execute('cancel', offer.id)">Decline</button></div></article>
      <h2>Sent offers</h2><p v-if="!outgoing.length" class="hint">No pending transfers.</p>
      <article v-for="offer in outgoing" :key="offer.id"><small>To {{ offer.to.name }}</small><h3>{{ offer.kind === 'money' ? 'Money transfer' : offer.title }}</h3><strong class="price">{{ currency(offer.cents / 100) }}</strong><p>Waiting for the recipient. Direct offers expire after 3 minutes.</p><button :disabled="busy" @click="execute('cancel', offer.id)">Cancel offer</button></article>
    </section>
    <section v-if="confirm" class="confirmation" role="dialog" aria-modal="true" aria-label="Confirm exchange">
      <h2>{{ confirm.op === 'buy' ? 'Buy this car?' : confirm.op === 'withdraw' ? 'Withdraw this listing?' : confirm.op === 'publish' ? 'Publish this listing?' : confirm.op === 'accept' ? 'Accept this offer?' : 'Send this transfer?' }}</h2>
      <p v-if="confirm.listing">{{ confirm.listing.title }} | {{ confirm.listing.seller }} | <strong>{{ currency(confirm.listing.cents / 100) }}</strong></p>
      <p v-else-if="confirm.offer">{{ confirm.offer.from.name }} | {{ confirm.offer.kind === 'car' ? confirm.offer.title : 'Money transfer' }} | <strong>{{ currency(confirm.offer.cents / 100) }}</strong></p>
      <p v-else>{{ confirm.carName || confirm.playerName }} | <strong>{{ currency(confirm.amount) }}</strong></p>
      <p v-if="confirm.op === 'publish'">Your car will be reserved. This listing has no expiry and stays available while you are offline. Sale proceeds reach this career when you next connect.</p>
      <p v-else-if="confirm.op === 'withdraw'">The listing will be removed and the car unlocked after your career saves.</p>
      <p v-else-if="confirm.op === 'buy'">The asking price will be taken from your wallet. You need a free garage space. The car arrives stored, without the seller's insurance.</p>
      <p v-else>The transaction waits for both careers to save.</p>
      <p>Stay connected and stopped while your save completes.</p>
      <div class="actions"><button class="primary" :disabled="busy" @click="confirmAction">Confirm</button><button :disabled="busy" @click="confirm = null">Back</button></div>
    </section>
    <footer><button :disabled="busy" @click="refresh">Refresh</button><small>Use your RLS wallet for purchases and transfers. Manage bank accounts in Bank.</small></footer>
  </main>
</template>
<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
const props = defineProps({callLua:{type:Function,required:true}})
const state=ref({}),tab=ref('marketplace'),target=ref(-1),vehicleId=ref(0),amount=ref(''),error=ref(''),busy=ref(false),confirm=ref(null),search=ref(''),sort=ref('newest')
const tabs=[{id:'marketplace',label:'Market'},{id:'sell',label:'Sell'},{id:'money',label:'Transfer'},{id:'offers',label:'Offers'}]
const list=v=>Array.isArray(v)?v:v&&typeof v==='object'?Object.values(v):[]
const players=computed(()=>list(state.value.players)),vehicles=computed(()=>list(state.value.vehicles)),listings=computed(()=>list(state.value.listings)),myListings=computed(()=>list(state.value.myListings))
const incoming=computed(()=>list(state.value.incoming)),outgoing=computed(()=>list(state.value.outgoing)),pending=computed(()=>list(state.value.pending))
const selectedPlayer=computed(()=>players.value.find(p=>p.id===target.value)),selectedCar=computed(()=>vehicles.value.find(c=>c.id===vehicleId.value))
const filteredListings=computed(()=>{
  const q=search.value.trim().toLowerCase()
  const rows=listings.value.filter(l=>`${l.title} ${l.model} ${l.seller}`.toLowerCase().includes(q))
  return rows.sort((a,b)=>sort.value==='low'?a.cents-b.cents:sort.value==='high'?b.cents-a.cents:b.created-a.created)
})
const blocked=computed(()=>busy.value||state.value.saving||!state.value.active||!state.value.enabled||pending.value.length>0)
const currency=v=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(Number(v)||0)
let timer,disposed=false,refreshing=false
async function refresh(){
  if(refreshing||disposed)return
  refreshing=true
  try{
    await props.callLua('rlsmpTeamx.tradeAction','refresh',0,0,0,'')
    const reply=await props.callLua('rlsmpTeamx.getTradeStatus')
    if(!disposed)state.value=reply||{}
  }catch(_){if(!disposed)error.value='The server is not responding. Please try again.'}
  finally{refreshing=false}
}
function review(){
  if(tab.value!=='money'&&tab.value!=='sell')return
  const value=Number(amount.value)
  if(!Number.isFinite(value)||value<=0||value>100000000||Math.abs(value*100-Math.round(value*100))>0.00001){error.value='Enter a positive amount with no more than two decimal places.';return}
  if(tab.value==='money'&&!selectedPlayer.value){error.value='Select a player.';return}
  if(tab.value==='sell'&&!selectedCar.value){error.value='Select a stored car.';return}
  confirm.value={op:tab.value==='money'?'money':'publish',target:target.value,amount:value,vehicleId:vehicleId.value,playerName:selectedPlayer.value?.name,carName:tab.value==='sell'?selectedCar.value.name:''}
}
async function execute(op,id='',details={}){
  if(busy.value)return
  busy.value=true;error.value=''
  try{
    const reply=await props.callLua('rlsmpTeamx.tradeAction',op,details.target??0,details.amount||0,details.vehicleId||0,id)
    if(!reply?.ok)error.value=reply?.error||'This action is unavailable.'
    else{confirm.value=null;if(op==='money'){amount.value='';tab.value='offers'}else if(op==='publish'){amount.value='';tab.value='sell'}}
    await refresh()
  }catch(_){error.value='Exchange unavailable. Refresh before trying again.'}
  finally{busy.value=false}
}
function confirmAction(){const c=confirm.value;if(c)return execute(c.op,c.offer?.id||c.listing?.id||'',c)}
onMounted(()=>{refresh();timer=setInterval(refresh,3000)})
onUnmounted(()=>{disposed=true;clearInterval(timer)})
</script>
<style scoped>
.exchanges{min-height:100%;box-sizing:border-box;padding:1.1rem;background:#121b22;color:#edf6f6;font-family:inherit}header{padding:.3rem 0 .8rem}.eyebrow{font-size:.65rem;letter-spacing:.12em;color:#7ed2c2}h1{font-size:1.45rem;margin:.35rem 0}h2{font-size:1.05rem;margin:1.1rem 0 .6rem}h3{font-size:1rem;margin:.3rem 0}p{line-height:1.45}header p{margin:.4rem 0;color:#bdced7}header strong{display:block;font-size:1.45rem;color:#fff}
nav,.actions{display:flex;gap:.35rem}nav button{flex:1;padding:.65rem .25rem;font-size:.8rem}button,select,input{font:inherit;border-radius:.5rem;box-sizing:border-box}button{border:1px solid #405361;background:#23313b;color:#fff;padding:.65rem .85rem;cursor:pointer}button.selected,.primary{background:#247366;border-color:#48aa97}button:disabled{opacity:.45;cursor:default}button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid #8ee3d0;outline-offset:2px}
label{display:block;margin:1rem 0;font-size:.85rem}select,input{display:block;width:100%;padding:.7rem;margin-top:.4rem;background:#1f2c35;border:1px solid #49606c;color:#fff}form>.primary{width:100%}.hint,small{color:#b9cbd4;font-size:.8rem}.notice{background:#263b48;padding:.8rem;border-radius:.6rem;font-size:.85rem}.notice p{margin:.4rem 0}.error{background:#542d36}article{padding:.85rem;margin:.7rem 0;border:1px solid #38505e;border-radius:.7rem;background:#1a2933}article p{font-size:.8rem;color:#b9cbd4}.price{color:#8ee3d0;font-size:1.25rem}
.section-title{display:flex;justify-content:space-between;align-items:center}.section-title>span{font-size:.8rem;color:#b9cbd4}.market-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,220px),1fr));gap:.8rem}.listing{padding:0;overflow:hidden;margin:0}.listing-body{padding:.85rem}.listing-body button{width:100%;margin-top:.5rem}.car-mark{padding:.8rem 1rem;background:linear-gradient(135deg,#203d49,#284d47);color:#8cc5b9}.car-mark svg{width:100%;height:70px}.car-mark span{text-transform:uppercase;letter-spacing:.1em;font-size:.65rem}.seller{display:flex;align-items:center;gap:.4rem}.badge{font-size:.65rem;border:1px solid #617681;border-radius:1rem;padding:.15rem .4rem;color:#bdced7}.badge.online{color:#8ee3d0;border-color:#348775}
.confirmation{position:fixed;z-index:10;inset:10% 5%;overflow:auto;padding:1rem;border:2px solid #7ed2c2;background:#172a34;border-radius:.8rem;box-shadow:0 0 0 100vmax #000b}.confirmation .actions{margin-top:1rem}footer{display:flex;flex-direction:column;gap:.7rem;margin-top:1.4rem;padding-top:.8rem;border-top:1px solid #38505e}
</style>
