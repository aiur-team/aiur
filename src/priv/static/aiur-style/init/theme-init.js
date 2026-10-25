(function () {
  var data = document.currentScript.dataset;
  var html = document.documentElement;
  var key = data.storageKey || 'aiur-theme';
  var banner = data.banner && 'aiur-banner:' + data.banner;
  var theme;
  var dismissed;
  function read(name) {
    try { return localStorage.getItem(name); } catch (e) { return null; }
  }
  function valid(value) { return value === 'light' || value === 'dark'; }
  theme = read(key);
  dismissed = banner && read(banner);
  (data.legacyKeys || '').split(/\s+/).forEach(function (oldKey) {
    if (!oldKey || oldKey === key || oldKey === banner) return;
    var value = read(oldKey);
    var target;
    if (!valid(theme) && valid(value)) {
      theme = value;
      target = key;
    } else if (banner && dismissed !== 'dismissed' && (value === 'dismissed' || value === '1')) {
      dismissed = 'dismissed';
      value = dismissed;
      target = banner;
    }
    if (target) {
      try {
        localStorage.setItem(target, value);
        localStorage.removeItem(oldKey);
      } catch (e) {}
    }
  });
  if (!valid(theme)) theme = data.default;
  if (valid(theme)) html.setAttribute('data-theme', theme);
  else html.removeAttribute('data-theme');
  if (dismissed === 'dismissed') html.setAttribute('data-aiur-banner', 'dismissed');
  if (data.vitepress === 'true') {
    try { localStorage.setItem('vitepress-theme-appearance', valid(theme) ? theme : 'auto'); } catch (e) {}
    html.classList.toggle('dark', valid(theme) ? theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches);
  }
}());
