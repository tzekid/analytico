// Heatmap overlay, drawn on the operator's live page. Opened from the
// workspace with a short-lived signed token; it fetches per-element click
// aggregates, scroll reach and attention for this page and draws them over
// the real, current page. Nothing about individual visitors is involved.
(function () {
  "use strict";

  window.__analyticoOverlay = function (options) {
    if (document.getElementById("analytico-overlay")) return;
    var state = { kind: "clicks", vp: viewportClass(), days: 30, data: null };
    var host = document.createElement("div");
    host.id = "analytico-overlay";
    host.style.cssText = "position:absolute;left:0;top:0;width:0;height:0;z-index:2147483647";
    var root = host.attachShadow({ mode: "open" });
    root.innerHTML = "<style>" +
      ":host{all:initial}" +
      ".layer{position:absolute;left:0;top:0;pointer-events:none}" +
      ".bar{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);display:flex;gap:6px;align-items:center;flex-wrap:wrap;justify-content:center;" +
      "background:#282421;color:#fff;border-radius:12px;padding:8px 10px;font:500 13px/18px system-ui,-apple-system,sans-serif;box-shadow:0 16px 40px -8px #0006;max-width:calc(100vw - 32px)}" +
      ".bar b{font-weight:700;margin:0 6px 0 4px}.seg{display:flex;background:#ffffff1a;border-radius:8px;padding:2px}" +
      ".seg button{all:unset;cursor:pointer;padding:4px 10px;border-radius:6px;color:#ffffffb3}.seg button[aria-pressed=true]{background:#fff;color:#282421}" +
      ".note{color:#ffffffb3;margin:0 6px}.close{all:unset;cursor:pointer;padding:4px 8px;border-radius:6px;color:#fff}.close:hover{background:#ffffff26}" +
      ".band{position:absolute;left:0;right:0;border-top:1px dashed #ffffffcc;font:600 12px system-ui,sans-serif;color:#fff;text-shadow:0 1px 2px #000}" +
      ".band span{position:absolute;right:16px;top:4px;background:#282421d9;padding:2px 8px;border-radius:6px;text-shadow:none}" +
      "</style><canvas class=\"layer\"></canvas><div class=\"layer bands\"></div>" +
      "<div class=\"bar\" role=\"toolbar\" aria-label=\"Heatmap\"><b>Analytico</b>" +
      "<div class=\"seg\" data-group=\"kind\"><button data-value=\"clicks\">Clicks</button><button data-value=\"scroll\">Scroll</button><button data-value=\"attention\">Attention</button></div>" +
      "<div class=\"seg\" data-group=\"vp\"><button data-value=\"desktop\">Desktop</button><button data-value=\"tablet\">Tablet</button><button data-value=\"phone\">Phone</button></div>" +
      "<div class=\"seg\" data-group=\"days\"><button data-value=\"7\">7d</button><button data-value=\"30\">30d</button><button data-value=\"90\">90d</button></div>" +
      "<span class=\"note\" aria-live=\"polite\"></span><button class=\"close\" aria-label=\"Close heatmap\">✕</button></div>";
    document.body.appendChild(host);
    var canvas = root.querySelector("canvas");
    var bands = root.querySelector(".bands");
    var note = root.querySelector(".note");

    root.querySelectorAll(".seg").forEach(function (group) {
      group.addEventListener("click", function (event) {
        var button = event.target.closest("button");
        if (!button) return;
        var key = group.getAttribute("data-group");
        state[key] = key === "days" ? Number(button.getAttribute("data-value")) : button.getAttribute("data-value");
        if (key === "kind") draw();
        else fetchData();
        pressed();
      });
    });
    root.querySelector(".close").addEventListener("click", function () {
      host.remove();
      history.replaceState(history.state, "", location.pathname + location.search);
    });
    addEventListener("resize", function () { draw(); });

    function pressed() {
      root.querySelectorAll(".seg").forEach(function (group) {
        var key = group.getAttribute("data-group");
        group.querySelectorAll("button").forEach(function (button) {
          button.setAttribute("aria-pressed", String(button.getAttribute("data-value") === String(state[key])));
        });
      });
    }

    function viewportClass() {
      var width = window.innerWidth;
      return width < 600 ? "phone" : width < 1024 ? "tablet" : "desktop";
    }

    function fetchData() {
      note.textContent = "Loading…";
      var url = options.origin + "/h?site=" + encodeURIComponent(options.site) + "&token=" + encodeURIComponent(options.token) +
        "&path=" + encodeURIComponent(location.pathname) + "&vp=" + state.vp + "&days=" + state.days;
      fetch(url, { method: "POST", credentials: "omit", headers: { "Content-Type": "text/plain" }, body: "" }).then(function (response) {
        if (!response.ok) throw new Error(response.status === 401 ? "This heatmap link has expired. Open it again from Analytico." : "Could not load the heatmap.");
        return response.json();
      }).then(function (data) {
        state.data = data;
        draw();
      }).catch(function (error) {
        note.textContent = error.message;
      });
    }

    function pageHeight() {
      return Math.max(document.documentElement.scrollHeight, document.body.scrollHeight);
    }

    function draw() {
      var data = state.data;
      if (!data) return;
      var width = document.documentElement.clientWidth;
      var height = Math.min(pageHeight(), 16000);
      canvas.width = width;
      canvas.height = height;
      canvas.style.width = width + "px";
      canvas.style.height = height + "px";
      bands.style.width = width + "px";
      bands.style.height = height + "px";
      bands.textContent = "";
      var context = canvas.getContext("2d");
      context.clearRect(0, 0, width, height);
      if (state.kind === "clicks") drawClicks(context, data, width, height);
      else if (state.kind === "scroll") drawScroll(context, data, width, height);
      else drawAttention(context, data, width, height);
    }

    function drawClicks(context, data, width, height) {
      var total = 0;
      var placed = 0;
      var peak = 1;
      data.clicks.forEach(function (cell) { peak = Math.max(peak, cell.n); });
      data.clicks.forEach(function (cell) {
        total += cell.n;
        var element = null;
        try {
          element = document.querySelector(cell.el);
        } catch (_) {}
        if (!element) return;
        var rect = element.getBoundingClientRect();
        if (!rect.width) return;
        placed += cell.n;
        var x = rect.left + window.scrollX + rect.width * cell.x / 100;
        var y = rect.top + window.scrollY + rect.height * cell.y / 100;
        var radius = 26;
        var gradient = context.createRadialGradient(x, y, 0, x, y, radius);
        var alpha = Math.min(1, 0.25 + 0.75 * cell.n / peak);
        gradient.addColorStop(0, "rgba(0,0,0," + alpha + ")");
        gradient.addColorStop(1, "rgba(0,0,0,0)");
        context.fillStyle = gradient;
        context.fillRect(x - radius, y - radius, radius * 2, radius * 2);
      });
      colorize(context, width, height);
      var missing = total - placed;
      note.textContent = total + " clicks · " + data.views + " views" + (missing > 0 ? " · " + Math.round(missing / total * 100) + "% on elements not on this page now" : "");
    }

    // Alpha intensity to a blue → green → yellow → red palette.
    function colorize(context, width, height) {
      if (!width || !height) return;
      var image = context.getImageData(0, 0, width, height);
      var pixels = image.data;
      for (var i = 0; i < pixels.length; i += 4) {
        var a = pixels[i + 3] / 255;
        if (!a) continue;
        var r = a < 0.5 ? 0 : Math.round(255 * Math.min(1, (a - 0.5) * 2.5));
        var g = a < 0.75 ? Math.round(255 * Math.min(1, a * 2)) : Math.round(255 * (1 - (a - 0.75) * 4));
        var b = a < 0.4 ? Math.round(255 * (1 - a * 2.5)) : 0;
        pixels[i] = r;
        pixels[i + 1] = Math.max(0, g);
        pixels[i + 2] = b;
        pixels[i + 3] = Math.round(Math.min(0.75, a * 0.9) * 255);
      }
      context.putImageData(image, 0, 0);
    }

    function drawScroll(context, data, width, height) {
      // data.scroll[k]: share of views that reached k * 5% of the page.
      var steps = data.scroll.length - 1;
      for (var k = 0; k < steps; k++) {
        var share = data.scroll[k + 1];
        context.fillStyle = "rgba(214,73,55," + (0.55 * (1 - share)).toFixed(3) + ")";
        context.fillRect(0, height * k / steps, width, height / steps + 1);
      }
      [0.75, 0.5, 0.25].forEach(function (mark) {
        for (var k = 1; k < data.scroll.length; k++) {
          if (data.scroll[k] < mark) {
            band(height * (k - 1) / steps, Math.round(mark * 100) + "% of visitors scrolled this far");
            return;
          }
        }
      });
      note.textContent = data.views + " views · average reach " + Math.round(data.average_scroll) + "%";
    }

    function drawAttention(context, data, width, height) {
      var peak = Math.max.apply(null, data.attention.concat([1]));
      data.attention.forEach(function (ms, index) {
        var strength = ms / peak;
        context.fillStyle = "rgba(214,73,55," + (0.6 * strength).toFixed(3) + ")";
        context.fillRect(0, height * index / 10, width, height / 10 + 1);
        band(height * index / 10, Math.round(ms / 1000) + " s average");
      });
      note.textContent = data.views + " views · where time was spent";
    }

    function band(top, label) {
      var line = document.createElement("div");
      line.className = "band";
      line.style.top = top + "px";
      var text = document.createElement("span");
      text.textContent = label;
      line.appendChild(text);
      bands.appendChild(line);
    }

    pressed();
    fetchData();
  };
}());
