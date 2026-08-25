"use strict";

(function () {
  var exclusionWindows = [];

  function liveRegion(element) {
    return element && typeof element.closest === "function" ?
      element.closest("[data-live-region]") : null;
  }

  function liveTimestamp(region) {
    if (region.dataset.liveTimestamp) return region.dataset.liveTimestamp;
    var time = region.querySelector("[data-live-generated]");
    var value = time ? time.textContent : "the last successful update";
    region.dataset.liveTimestamp = value;
    return value;
  }

  function revealLiveControls(root) {
    var region = root.matches && root.matches("[data-live-region]") ? root :
      root.querySelector && root.querySelector("[data-live-region]");
    if (!region) return;
    var pause = region.querySelector("[data-live-pause]");
    if (pause) pause.hidden = false;
  }

  function eventLiveRegion(event) {
    return liveRegion(event.target) ||
      liveRegion(event.detail && event.detail.ctx &&
        event.detail.ctx.sourceElement);
  }

  function markLiveStale(event) {
    var region = eventLiveRegion(event);
    if (!region) return;
    region.dataset.liveStale = "true";
    var status = region.querySelector("[data-live-client-status]");
    if (status) status.textContent = "Update failed; showing snapshot from " +
      liveTimestamp(region) + ". Automatic refresh will retry.";
  }

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
    var pause = target && typeof target.closest === "function" ?
      target.closest("[data-live-pause]") : null;
    if (pause) {
      var region = liveRegion(pause);
      var paused = region.dataset.livePaused !== "true";
      region.dataset.livePaused = paused ? "true" : "false";
      pause.setAttribute("aria-pressed", paused ? "true" : "false");
      pause.textContent = paused ? "Resume automatic refresh" :
        "Pause automatic refresh";
      var status = region.querySelector("[data-live-client-status]");
      if (status) status.textContent = (paused ?
        "Automatic refresh paused. Snapshot from " :
        "Automatic refresh resumed. Snapshot from ") +
        liveTimestamp(region) + ".";
      return;
    }
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

  document.addEventListener("DOMContentLoaded", function () {
    revealLiveControls(document);
  });

  document.addEventListener("htmx:before:request", function (event) {
    var region = eventLiveRegion(event);
    if (!region) return;
    if (region.dataset.livePaused === "true" || document.hidden) {
      event.preventDefault();
    }
  });

  document.addEventListener("htmx:response:error", markLiveStale);
  document.addEventListener("htmx:error", markLiveStale);

  document.addEventListener("htmx:after:swap", function () {
    revealLiveControls(document);
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
