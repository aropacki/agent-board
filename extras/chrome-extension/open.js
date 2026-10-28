// Agent Board opens this page with #<url-encoded JSON {title, urls, focus}>.
// It opens the links as one named tab group in this window, then closes itself.
(async () => {
  const me = await chrome.tabs.getCurrent();
  let request = {};
  try { request = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch {}
  const urls = (request.urls || []).filter((u) => /^https?:\/\//.test(u));
  if (urls.length) {
    const tabs = [];
    for (const [i, url] of urls.entries()) {
      tabs.push(await chrome.tabs.create({ windowId: me.windowId, index: me.index + i, url, active: false }));
    }
    const groupId = await chrome.tabs.group({ tabIds: tabs.map((t) => t.id), createProperties: { windowId: me.windowId } });
    await chrome.tabGroups.update(groupId, { title: request.title || "", collapsed: false });
    if (request.focus) await chrome.tabs.update(tabs[0].id, { active: true });
  }
  await chrome.tabs.remove(me.id);
})();
