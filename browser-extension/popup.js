// The popup: shows whether Benji is connected, and is the one place the user gives (or takes
// back) the extension's access to sites. Chrome asks for it itself, and only on a click here.
const ORIGINS = ["https://*/*"];
const $ = (id) => document.getElementById(id);

async function refresh() {
  const status = await chrome.runtime.sendMessage({ type: "status" }).catch(() => null);
  $("state").textContent = status && status.connected
    ? "Connected to Benji."
    : (status && status.note) || "Not connected to Benji.";
  const granted = await chrome.permissions.contains({ origins: ORIGINS });
  $("access").textContent = granted
    ? "Benji may use pages in its tab group, on the sites you approve for each job."
    : "Benji can't read any page until you allow it here.";
  $("allow").hidden = granted;
  $("remove").hidden = !granted;
}

$("allow").addEventListener("click", async () => {
  await chrome.permissions.request({ origins: ORIGINS });
  await chrome.runtime.sendMessage({ type: "connect" }).catch(() => null);
  refresh();
});
$("remove").addEventListener("click", async () => {
  await chrome.permissions.remove({ origins: ORIGINS });
  refresh();
});
chrome.runtime.sendMessage({ type: "connect" }).catch(() => null).then(refresh);
