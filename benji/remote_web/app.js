'use strict';
const el = id => document.getElementById(id);
let key = '', state = null, pending = null, busy = false, generation = 0, attempt = 0, stateCache = null;
const message = text => { el('message').textContent = text; };
const newID = () => crypto.randomUUID();
async function api(path, body) {
  const cached = path === '/api/state' ? stateCache : null, epoch = generation;
  const response = await fetch(path, {method: body ? 'POST' : 'GET', cache: 'no-store',
    credentials: 'omit', headers: {'Authorization': `Bearer ${key}`, ...(cached ? {'If-None-Match': cached.etag} : {}), ...(body ? {'Content-Type': 'application/json'} : {})},
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(6000)});
  if (response.status === 304 && cached) return cached.data;
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || 'Request failed.');
  if (path === '/api/state' && epoch === generation) stateCache = {data, etag: response.headers.get('ETag')};
  return data;
}
function render(s) {
  state = s;
  el('connection').textContent = s.connected ? 'Connected to your Mac' : 'Mac is not responding';
  el('send').disabled = !s.available || !!pending || busy;
  el('availability').textContent = !s.connected ? 'Reconnect to your Mac to send a task.' : (s.unavailableReason || '');
  el('task').hidden = !s.task;
  if (!s.task) return;
  const t = s.task;
  el('task-title').textContent = t.text;
  el('task-status').textContent = t.status;
  const signature = JSON.stringify(t.lines);
  if (el('lines').dataset.signature !== signature) {
    el('lines').replaceChildren(...(t.lines || []).map(line => {
      const p = document.createElement('p'); p.textContent = line.text; p.dataset.role = line.role; return p;
    }));
    el('lines').dataset.signature = signature;
  }
  el('stream').textContent = t.stream || '';
  el('approval').hidden = !t.approval;
  if (t.approval) {
    el('action').textContent = t.approval.action; el('target').textContent = t.approval.target;
    // Without an id the Mac answers this one: approvals from the phone are off in Settings › Phone.
    const here = !!t.approval.id;
    el('approval-actions').hidden = !here;
    el('approval-hint').textContent = here ? 'This request expires on the Mac. Read the full action before approving.'
      : 'Waiting for your answer on the Mac. Approvals from the phone are turned off.';
  }
  el('stop').hidden = !t.running;
  for (const id of ['approve', 'deny']) el(id).disabled = !s.connected || busy || !!pending;
  // An uncertain approval must never disable the owner's ability to request a stop.
  el('stop').disabled = !s.connected || pending?.op === 'stop';
}
async function refresh(epoch = generation) {
  try {
    const s = await api('/api/state');
    if (epoch !== generation) return;
    render(s);
    if (pending) {
      const receipt = await api(`/api/receipt/${pending.id}`);
      if (epoch !== generation) return;
      settle(receipt);
    }
  } catch (error) {
    if (epoch !== generation) return;
    el('connection').textContent = 'Connection lost';
    if (state) render({...state, connected: false, available: false});
    message(`${error.message} ${pending ? 'Your last request may have arrived. Retry uses the same ID.' : ''}`);
  }
}
function settle(receipt) {
  if (!pending || receipt.id !== pending.id || receipt.result === null) return;
  const done = pending; pending = null; el('retry').hidden = true;
  message(receipt.result.message || (receipt.result.ok ? 'Request received by your Mac.' : 'Request declined.'));
  if (receipt.result.ok && done.op === 'send' && el('prompt').value === done.text) el('prompt').value = '';
  if (state) render(state);
}
async function send(value) {
  if (busy && value.op !== 'stop') return;
  pending = value; busy = true; el('retry').hidden = true;
  if (state) render(state);
  const epoch = generation, thisAttempt = ++attempt;
  try {
    const receipt = await api('/api/command', value);
    if (epoch !== generation || thisAttempt !== attempt) return;
    settle(receipt);
    if (pending) message('Waiting for the Mac to acknowledge this request…');
  } catch (error) {
    if (epoch !== generation || thisAttempt !== attempt) return;
    // Keep the exact request for retry after every uncertain response, never mint a new ID.
    message(`${error.message} Retry will use the same request.`);
  } finally {
    if (epoch === generation && thisAttempt === attempt) {
      busy = false; el('retry').hidden = !pending;
      await refresh(epoch);
    }
  }
}
el('connect').onclick = async () => {
  key = el('key').value.trim(); if (!key) return;
  generation++; stateCache = null;
  el('connect').disabled = true;
  try {
    const s = await api('/api/state');
    el('key').value = ''; el('pair').hidden = true; el('controls').hidden = false; message(''); render(s);
  } catch (error) { key = ''; message(error.message); }
  finally { el('connect').disabled = false; }
};
el('disconnect').onclick = () => {
  generation++; stateCache = null; key = ''; pending = null; state = null; busy = false;
  el('controls').hidden = true; el('pair').hidden = false; el('connection').textContent = 'Not connected';
  el('lines').replaceChildren(); el('lines').dataset.signature = ''; el('stream').textContent = ''; el('prompt').value = '';
  message('Disconnected. Any task already running on the Mac continues.');
};
el('send').onclick = () => {
  const text = el('prompt').value.trim();
  if (text && state?.available && !pending) send({id:newID(), op:'send', text});
};
el('retry').onclick = () => { if (pending) send(pending); };
el('stop').onclick = () => { if (state?.task?.running && pending?.op !== 'stop') send({id:newID(), op:'stop', task:state.task.id}); };
for (const [id, approved] of [['approve',true], ['deny',false]]) el(id).onclick = () => {
  const t = state?.task;
  if (t?.approval?.id && !pending) send({id:newID(), op:'approve', task:t.id, request:t.approval.id, approved});
};
async function poll() {
  if (key && !el('controls').hidden && !busy) await refresh();
  setTimeout(poll, 1000);
}
poll();
