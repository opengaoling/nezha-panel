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

  function loginTarget() {
    return window.location.pathname.indexOf("/dashboard") === 0 ? "/dashboard/login" : "/";
  }

  function redirectForAuth() {
    if (redirected) return;
    redirected = true;
    clearAuthStorage();
    var target = loginTarget();
    if (window.location.pathname + window.location.search !== target) {
      window.location.replace(target);
    }
  }

  function shouldRedirect(response) {
    if (!response) return false;
    if (response.headers && response.headers.get(authHeader) === "1") return true;
    if (response.status === 401) return true;
    return false;
  }

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
})();
