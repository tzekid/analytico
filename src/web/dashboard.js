"use strict";

(function () {
  var exclusionWindows = [];

  document.addEventListener("change", function (event) {
    var select = event.target;
    if (!select.matches('[data-site-switcher] select[name="site"]')) return;
    var form = select.form;
    if (form && typeof form.requestSubmit === "function") form.requestSubmit();
  });

  document.addEventListener("click", function (event) {
    if (event.button !== 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey) return;
    var target = event.target;
    var link = target && typeof target.closest === "function" ?
      target.closest("a[data-self-exclusion]") : null;
    if (!link) return;
    var child = window.open(link.href, "_blank");
    if (!child) return;
    event.preventDefault();
    if (exclusionWindows.length === 4) exclusionWindows.shift();
    exclusionWindows.push({
      child: child,
      site: link.dataset.site,
      action: link.dataset.selfExclusion,
      origin: link.dataset.origin,
    });
  });

  window.addEventListener("message", function (event) {
    var data = event.data;
    if (!data || typeof data !== "object") return;
    for (var index = 0; index < exclusionWindows.length; index++) {
      var pending = exclusionWindows[index];
      if (event.source !== pending.child || event.origin !== pending.origin ||
          data.site !== pending.site || data.action !== pending.action) continue;
      if (data.analytico === "self-exclusion-ready") {
        pending.child.postMessage({
          analytico: "self-exclusion-apply",
          site: pending.site,
          action: pending.action,
        }, pending.origin);
      } else if (data.analytico === "self-exclusion-applied") {
        exclusionWindows.splice(index, 1);
      }
      return;
    }
  });
})();
