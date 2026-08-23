"use strict";

(function () {
  document.addEventListener("change", function (event) {
    var select = event.target;
    if (!select.matches('[data-site-switcher] select[name="site"]')) return;
    var form = select.form;
    if (form && typeof form.requestSubmit === "function") form.requestSubmit();
  });
})();
