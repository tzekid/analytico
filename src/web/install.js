"use strict";

(function () {
  var verification = document.querySelector("[data-install-verification]");
  var timer = 0;
  var paused = false;
  var inFlight = false;

  function pauseButton() {
    return verification && verification.querySelector("[data-verification-pause]");
  }

  function clientStatus() {
    return verification && verification.querySelector("[data-verification-client-status]");
  }

  function clearTimer() {
    if (!timer) return;
    window.clearTimeout(timer);
    timer = 0;
  }

  function updatePauseButton() {
    var button = pauseButton();
    if (!button) return;
    button.hidden = verification.dataset.state !== "waiting";
    button.setAttribute("aria-pressed", paused ? "true" : "false");
    button.textContent = paused ? "Resume automatic checks" : "Pause automatic checks";
  }

  function schedule() {
    clearTimer();
    updatePauseButton();
    if (!verification || verification.dataset.state !== "waiting" || paused ||
        document.hidden || inFlight) return;
    timer = window.setTimeout(refresh, 5000);
  }

  async function refresh() {
    timer = 0;
    if (!verification || verification.dataset.state !== "waiting" || paused ||
        document.hidden || inFlight) return;
    inFlight = true;
    try {
      var response = await window.fetch(verification.dataset.fragmentUrl, {
        cache: "no-store",
        credentials: "same-origin",
        headers: { Accept: "text/html" },
        referrerPolicy: "no-referrer",
      });
      if (!response.ok) throw new Error("verification request failed");
      var documentResponse = new DOMParser().parseFromString(
        await response.text(),
        "text/html",
      );
      var replacement = documentResponse.querySelector("[data-install-verification]");
      if (!replacement) throw new Error("verification response was incomplete");
      verification.replaceWith(document.importNode(replacement, true));
      verification = document.querySelector("[data-install-verification]");
      var status = clientStatus();
      if (status) status.textContent = "";
    } catch (_) {
      paused = true;
      var status = clientStatus();
      if (status) {
        status.textContent = "Automatic checking paused after a request failed. Use Check again or resume automatic checks.";
      }
    } finally {
      inFlight = false;
      schedule();
    }
  }

  async function copySnippet(button) {
    var field = document.getElementById(button.dataset.copyTarget || "");
    var status = document.getElementById(button.dataset.copyStatus || "");
    if (!field || !status) return;
    try {
      if (!navigator.clipboard || !navigator.clipboard.writeText) {
        throw new Error("clipboard unavailable");
      }
      await navigator.clipboard.writeText(field.value);
      status.textContent = "Snippet copied.";
    } catch (_) {
      field.focus();
      field.select();
      status.textContent = "Clipboard unavailable. The snippet is selected for manual copy.";
    }
  }

  document.addEventListener("click", function (event) {
    var target = event.target;
    var copy = target && typeof target.closest === "function" ?
      target.closest("[data-copy-target]") : null;
    if (copy) {
      copySnippet(copy);
      return;
    }
    var pause = target && typeof target.closest === "function" ?
      target.closest("[data-verification-pause]") : null;
    if (!pause || !verification || !verification.contains(pause)) return;
    paused = !paused;
    var status = clientStatus();
    if (status) {
      status.textContent = paused ?
        "Automatic checking paused. Manual Check again remains available." :
        "Automatic checking resumed.";
    }
    schedule();
  });

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) clearTimer();
    else schedule();
  });

  if (verification) schedule();
})();
