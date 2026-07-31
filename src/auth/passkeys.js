(function () {
  "use strict";

  function supported() {
    return Boolean(window.isSecureContext && window.PublicKeyCredential && navigator.credentials);
  }

  function fromBase64url(value) {
    var base64 = String(value).replace(/-/g, "+").replace(/_/g, "/");
    var padded = base64 + "=".repeat((4 - base64.length % 4) % 4);
    var binary = window.atob(padded);
    var bytes = new Uint8Array(binary.length);
    for (var index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes.buffer;
  }

  function toBase64url(value) {
    var bytes = new Uint8Array(value);
    var binary = "";
    for (var index = 0; index < bytes.length; index += 1) binary += String.fromCharCode(bytes[index]);
    return window.btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function creationOptions(publicKey) {
    var options = Object.assign({}, publicKey, {
      challenge: fromBase64url(publicKey.challenge),
      user: Object.assign({}, publicKey.user, { id: fromBase64url(publicKey.user.id) })
    });
    options.excludeCredentials = (publicKey.excludeCredentials || []).map(function (item) {
      return Object.assign({}, item, { id: fromBase64url(item.id) });
    });
    return options;
  }

  function registrationPayload(challengeId, credential, label) {
    var transports = typeof credential.response.getTransports === "function"
      ? credential.response.getTransports()
      : [];
    return {
      challenge_id: challengeId,
      credential_id: toBase64url(credential.rawId),
      client_data_json: toBase64url(credential.response.clientDataJSON),
      attestation_object: toBase64url(credential.response.attestationObject),
      transports: transports.join(","),
      label: label || "Passkey"
    };
  }

  function requestOptions(publicKey) {
    var options = Object.assign({}, publicKey, {
      challenge: fromBase64url(publicKey.challenge)
    });
    options.allowCredentials = (publicKey.allowCredentials || []).map(function (item) {
      return Object.assign({}, item, { id: fromBase64url(item.id) });
    });
    return options;
  }

  function authenticationPayload(challengeId, credential) {
    return {
      challenge_id: challengeId,
      credential_id: toBase64url(credential.rawId),
      client_data_json: toBase64url(credential.response.clientDataJSON),
      authenticator_data: toBase64url(credential.response.authenticatorData),
      signature: toBase64url(credential.response.signature)
    };
  }

  async function post(url, body, bootstrapToken, csrfToken) {
    var headers = { "Content-Type": "application/json", Accept: "application/json" };
    if (bootstrapToken) headers["X-Analytico-Bootstrap"] = bootstrapToken;
    if (csrfToken) headers["X-Analytico-Csrf"] = csrfToken;
    var response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: headers,
      body: JSON.stringify(body || {})
    });
    var data = await response.json().catch(function () { return {}; });
    if (!response.ok) throw new Error(data.error || "The passkey request failed (" + response.status + ").");
    return data;
  }

  function setupPage() {
    var form = document.getElementById("setup-form");
    if (!form) return;
    var button = document.getElementById("setup-button");
    var error = document.getElementById("setup-error");
    var label = document.getElementById("passkey-label");
    var fragment = window.location.hash.indexOf("#token=") === 0
      ? window.location.hash.slice("#token=".length)
      : "";
    var token = "";
    try { token = decodeURIComponent(fragment); } catch (_) {}
    window.history.replaceState(null, document.title, window.location.pathname);

    if (!token) {
      button.disabled = true;
      error.textContent = "Open the complete one-use setup link printed by the Analytico CLI.";
      return;
    }
    if (!supported()) {
      button.disabled = true;
      error.textContent = "Passkeys require a current browser and a secure connection.";
      return;
    }
    form.addEventListener("submit", async function (event) {
      event.preventDefault();
      error.textContent = "";
      button.disabled = true;
      button.textContent = "Waiting for your device…";
      try {
        var options = await post("/admin/auth/setup/options", {}, token);
        var credential = await navigator.credentials.create({ publicKey: creationOptions(options.publicKey) });
        if (!credential) throw new Error("Passkey creation was cancelled.");
        await post(
          "/admin/auth/setup/verify",
          registrationPayload(options.challenge_id, credential, label.value.trim()),
          token
        );
        token = "";
        window.location.replace("/admin");
      } catch (failure) {
        error.textContent = failure && failure.name === "NotAllowedError"
          ? "Passkey creation was cancelled or timed out."
          : failure.message;
      } finally {
        button.disabled = false;
        button.textContent = "Create passkey";
      }
    });
  }

  function loginPage() {
    var button = document.getElementById("login-button");
    if (!button) return;
    var error = document.getElementById("login-error");
    if (!supported()) {
      button.disabled = true;
      error.textContent = "Passkeys require a current browser and a secure connection.";
      return;
    }
    button.addEventListener("click", async function () {
      error.textContent = "";
      button.disabled = true;
      button.textContent = "Waiting for your device…";
      try {
        var options = await post("/admin/auth/login/options", {});
        var credential = await navigator.credentials.get({ publicKey: requestOptions(options.publicKey) });
        if (!credential) throw new Error("Passkey sign-in was cancelled.");
        await post(
          "/admin/auth/login/verify",
          authenticationPayload(options.challenge_id, credential)
        );
        window.location.replace(document.body.dataset.return || "/admin");
      } catch (failure) {
        error.textContent = failure && failure.name === "NotAllowedError"
          ? "Passkey sign-in was cancelled or timed out."
          : failure.message;
      } finally {
        button.disabled = false;
        button.textContent = "Use a passkey";
      }
    });
  }

  function addPasskeyPage() {
    var form = document.getElementById("add-passkey-form");
    if (!form) return;
    var button = document.getElementById("add-passkey-button");
    var error = document.getElementById("add-passkey-error");
    var label = document.getElementById("add-passkey-label");
    var csrf = form.querySelector('input[name="csrf"]').value;
    if (!supported()) {
      button.disabled = true;
      error.textContent = "Passkeys require a current browser and a secure connection.";
      return;
    }
    form.addEventListener("submit", async function (event) {
      event.preventDefault();
      error.textContent = "";
      button.disabled = true;
      button.textContent = "Waiting for your device…";
      try {
        var options = await post("/admin/security/passkeys/options", {}, "", csrf);
        var credential = await navigator.credentials.create({ publicKey: creationOptions(options.publicKey) });
        if (!credential) throw new Error("Passkey creation was cancelled.");
        await post(
          "/admin/security/passkeys/verify",
          registrationPayload(options.challenge_id, credential, label.value.trim()),
          "",
          csrf
        );
        window.location.replace("/admin/security?notice=passkey-added");
      } catch (failure) {
        error.textContent = failure && failure.name === "NotAllowedError"
          ? "Passkey creation was cancelled or timed out."
          : failure.message;
      } finally {
        button.disabled = false;
        button.textContent = "Add passkey";
      }
    });
  }

  setupPage();
  loginPage();
  addPasskeyPage();
})();
