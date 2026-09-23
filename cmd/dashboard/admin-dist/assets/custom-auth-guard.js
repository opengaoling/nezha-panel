(function () {
  if (window.__nezhaAuthGuardInstalled) return;
  window.__nezhaAuthGuardInstalled = true;

  var redirected = false;
  var authHeader = "X-Nezha-Auth-Invalid";
  var lastKeepAliveAt = 0;
  var keepAliveInterval = 25 * 60 * 1000;

  function requestURL(input) {
    return typeof input === "string" ? input : input && input.url;
  }

  function sameOriginPath(input, path) {
    try {
      var raw = requestURL(input);
      if (!raw) return false;
      var url = new URL(raw, window.location.href);
      return url.origin === window.location.origin && url.pathname === path;
    } catch (_e) {
      return false;
    }
  }

  function sameOriginApi(input) {
    try {
      var raw = requestURL(input);
      if (!raw) return false;
      var url = new URL(raw, window.location.href);
      return url.origin === window.location.origin && url.pathname.indexOf("/api/v1/") === 0;
    } catch (_e) {
      return false;
    }
  }

  function requestMethod(input, init) {
    return String((init && init.method) || (input && input.method) || "GET").toUpperCase();
  }

  function cookieValue(name) {
    try {
      var prefix = name + "=";
      var parts = document.cookie ? document.cookie.split(";") : [];
      for (var i = 0; i < parts.length; i += 1) {
        var part = parts[i].trim();
        if (part.indexOf(prefix) === 0) return decodeURIComponent(part.slice(prefix.length));
      }
    } catch (_e) {}
    return "";
  }

  function hasSessionCookie() {
    return !!cookieValue("nz-jwt");
  }

  function withCSRF(init) {
    var next = Object.assign({}, init || {});
    var headers = new Headers(next.headers || {});
    var token = cookieValue("nz-csrf");
    if (token && !headers.has("X-CSRF-Token")) headers.set("X-CSRF-Token", token);
    next.headers = headers;
    next.credentials = next.credentials || "same-origin";
    return next;
  }

  function normalizeRefreshRequest(input, init) {
    if (!sameOriginPath(input, "/api/v1/refresh-token")) {
      return { input: input, init: init };
    }
    var next = withCSRF(init);
    if (requestMethod(input, init) === "GET") next.method = "POST";
    return { input: "/api/v1/refresh-token", init: next };
  }

  function refreshSession() {
    if (!hasSessionCookie() || !nativeFetch) return;
    lastKeepAliveAt = Date.now();
    nativeFetch.call(window, "/api/v1/refresh-token", withCSRF({ method: "POST" })).catch(function () {});
  }

  function maybeKeepAlive() {
    if (!hasSessionCookie() || Date.now() - lastKeepAliveAt < keepAliveInterval) return;
    refreshSession();
  }

  function clearAuthStorage() {
    try {
      document.cookie = "nz-jwt=; Max-Age=0; path=/; SameSite=Lax";
      document.cookie = "nz-csrf=; Max-Age=0; path=/; SameSite=Strict";
    } catch (_e) {}
    try {
      localStorage.removeItem("token");
      localStorage.removeItem("nezha-token");
      localStorage.removeItem("jwt");
      sessionStorage.removeItem("token");
      sessionStorage.removeItem("nezha-token");
      sessionStorage.removeItem("jwt");
    } catch (_e) {}
  }

  function getSecretPrefix() {
    try {
      var prefix = "nz-secret-path=";
      var cookieParts = document.cookie ? document.cookie.split(";") : [];
      for (var i = 0; i < cookieParts.length; i++) {
        var part = cookieParts[i].trim();
        if (part.indexOf(prefix) === 0) {
          var val = decodeURIComponent(part.substring(prefix.length)).trim();
          if (val) return "/" + val;
        }
      }
      var parts = window.location.pathname.split("/").filter(Boolean);
      if (parts.length > 0 && /^[a-zA-Z]{8}$/.test(parts[0])) {
        var first = parts[0].toLowerCase();
        if (first !== "settings" && first !== "terminal" && first !== "transfer") {
          return "/" + parts[0];
        }
      }
      var stored = localStorage.getItem("nz-secret-path");
      if (stored && /^[a-zA-Z]{8}$/.test(stored)) {
        return "/" + stored;
      }
    } catch (_e) {}
    return "";
  }

  function loginTarget() {
    var prefix = getSecretPrefix();
    return (prefix || "") + "/?redirect=" + encodeURIComponent(window.location.pathname + window.location.search);
  }

  function redirectForAuth() {
    // If we're already on the WAF gateway or login page, don't loop
    var path = window.location.pathname;
    if (path.indexOf("/dashboard/login") !== -1) return;
    var suffix = path.split("/").pop();
    if (suffix === "" || suffix === "login") return;
    if (redirected) return;
    redirected = true;
    clearAuthStorage();
    var target = loginTarget();
    window.location.replace(target);
  }

  function shouldRedirect(response) {
    if (!response) return false;
    if (window.location.pathname.indexOf("/dashboard/login") !== -1) return false;
    if (response.headers && response.headers.get(authHeader) === "1") return true;
    if (response.status === 401 && hasSessionCookie()) return true;
    return false;
  }

  function handleHomeClick(e) {
    var a = e.target && (e.target.tagName === "A" ? e.target : e.target.closest("a"));
    if (!a) return;
    var href = a.getAttribute("href");
    var isHome = href === "/" || href === "" || (a.pathname === "/" && a.origin === window.location.origin);
    if (isHome) {
      var prefix = getSecretPrefix();
      if (prefix) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        window.location.href = prefix + "/";
      }
    }
  }
  document.addEventListener("click", handleHomeClick, true);

  function fixHomeLinks() {
    var prefix = getSecretPrefix();
    if (!prefix) return;
    var links = document.querySelectorAll('a[href="/"], a[href=""]');
    for (var i = 0; i < links.length; i++) {
      links[i].setAttribute("href", prefix + "/");
    }
  }

  try {
    var detectedPrefix = getSecretPrefix();
    if (detectedPrefix) {
      var rawSec = detectedPrefix.replace(/^\//, "");
      localStorage.setItem("nz-secret-path", rawSec);
      document.cookie = "nz-secret-path=" + rawSec + "; path=/; Max-Age=2592000; SameSite=Lax";
    }
  } catch (_e) {}

  var nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    window.fetch = function (input, init) {
      var normalized = normalizeRefreshRequest(input, init);
      input = normalized.input;
      init = normalized.init;

      var api = sameOriginApi(input);
      var method = requestMethod(input, init);
      if (api && !sameOriginPath(input, "/api/v1/login") && !sameOriginPath(input, "/api/v1/refresh-token") && method !== "GET" && method !== "HEAD" && method !== "OPTIONS") {
        init = withCSRF(init);
      }

      return nativeFetch.call(this, input, init).then(function (response) {
        if (api && shouldRedirect(response)) {
          redirectForAuth();
          return new Response(JSON.stringify({
            success: false,
            error: "ApiErrorUnauthorized"
          }), {
            status: 401,
            headers: {
              "content-type": "application/json",
              "X-Nezha-Auth-Invalid": "1"
            }
          });
        }
        if (api) maybeKeepAlive();
        return response;
      });
    };
  }

  var NativeXHR = window.XMLHttpRequest;
  if (typeof NativeXHR === "function") {
    var nativeOpen = NativeXHR.prototype.open;
    var nativeSend = NativeXHR.prototype.send;

    NativeXHR.prototype.open = function (method, url) {
      this.__nezhaApiRequest = sameOriginApi(url);
      return nativeOpen.apply(this, arguments);
    };

    NativeXHR.prototype.send = function () {
      if (this.__nezhaApiRequest) {
        this.addEventListener("load", function () {
          var authInvalid = "";
          try {
            authInvalid = this.getResponseHeader(authHeader) || "";
          } catch (_e) {}
          if (this.status === 401 || authInvalid === "1") {
            redirectForAuth();
          }
        });
      }
      return nativeSend.apply(this, arguments);
    };
  }

  window.setInterval(maybeKeepAlive, 5 * 60 * 1000);
  window.addEventListener("focus", maybeKeepAlive);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) maybeKeepAlive();
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", fixHomeLinks, { once: true });
  } else {
    fixHomeLinks();
  }
  if (typeof MutationObserver !== "undefined") {
    var observer = new MutationObserver(function () {
      fixHomeLinks();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
  }
})();
