// Benji's browser extension. The service worker keeps one connection to Benji's
// native-messaging host (com.emerssive.heybenji.browser) and answers its requests with core.js. It never opens a
// page, reads a tab, clicks or types on its own: it only answers Benji, and core.js holds the rules.
import { Browser } from "./core.js";
import { pageAct } from "./page-actions.js";
import { visibleText } from "./page-text.js";

const HOST = "com.emerssive.heybenji.browser";
const core = new Browser(chrome, visibleText, undefined, pageAct);
let port = null;
const state = { connected: false, note: "" };

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch {
    state.note = "Benji isn't set up for this browser: turn on Settings, Browser, in the Benji app.";
    return;
  }
  const mine = port;
  mine.onMessage.addListener((msg) => onHost(mine, msg));
  mine.onDisconnect.addListener(() => {
    const why = chrome.runtime.lastError ? chrome.runtime.lastError.message : "";
    state.connected = false;
    state.note = /not found|forbidden/i.test(why)
      ? "Benji isn't set up for this browser: turn on Settings, Browser, in the Benji app."
      : "Benji isn't running or the switch in its Settings is off.";
    if (port === mine) port = null;
  });
  mine.postMessage({ type: "hello", version: chrome.runtime.getManifest().version });
}

async function onHost(from, msg) {
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "ready") {
    state.connected = true;
    state.note = "";
    return;
  }
  if (msg.type === "unavailable") {      // the host could not reach Benji's engine
    state.connected = false;
    state.note = "Benji isn't running or the switch in its Settings is off.";
    return;
  }
  if (typeof msg.id !== "string" || typeof msg.op !== "string") return;   // anything else is ignored
  const reply = await core.handle(msg);
  if (port === from) from.postMessage(reply);
}

chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create("benji-reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => { if (alarm.name === "benji-reconnect") connect(); });
connect();

// The popup (this extension's own page) asks for the state; nothing else can.
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (sender.id !== chrome.runtime.id || !msg) return false;
  if (msg.type === "status") {
    reply({ connected: state.connected, note: state.note });
  } else if (msg.type === "connect") {
    connect();
    reply({ connected: state.connected, note: state.note });
  }
  return false;
});
