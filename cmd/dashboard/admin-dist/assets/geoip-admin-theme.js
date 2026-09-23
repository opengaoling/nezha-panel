(function () {
  if (window.__geoipAdminThemeInstalled) return;
  window.__geoipAdminThemeInstalled = true;

  var version = "admin-theme-20260923b";
  try {
    var m = document.cookie.match(/nz-secret-path=([a-zA-Z0-9]+)/);
    var prefix = m && m[1] ? "/" + m[1] : "";
    if (!prefix) {
      var parts = window.location.pathname.split("/").filter(Boolean);
      if (parts.length > 0 && /^[a-zA-Z]{8}$/.test(parts[0])) {
        prefix = "/" + parts[0];
      }
    }
    if (!prefix) {
      var s = localStorage.getItem("nz-secret-path");
      if (s && /^[a-zA-Z]{8}$/.test(s)) prefix = "/" + s;
    }
    window.__nzHomeHref = (prefix || "") + "/";
  } catch (_e) {
    window.__nzHomeHref = "/";
  }
  var scripts = [
    "/dashboard/assets/geoip-auth-guard.js",
    "/dashboard/assets/geoip-session-timeout-setting-20260616.js",
    "/dashboard/assets/geoip-scroll-tools-20260613.js",
    "/dashboard/assets/geoip-admin-new-server-guest-setting.js"
  ];

  function versioned(src) {
    return src + "?v=" + version;
  }

  function loadScripts() {
    scripts.forEach(function (src) {
      var script = document.createElement("script");
      script.src = versioned(src);
      script.defer = true;
      document.head.appendChild(script);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", loadScripts, { once: true });
  } else {
    loadScripts();
  }
})();
