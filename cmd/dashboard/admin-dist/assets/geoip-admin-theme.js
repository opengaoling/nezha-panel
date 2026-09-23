(function () {
  if (window.__geoipAdminThemeInstalled) return;
  window.__geoipAdminThemeInstalled = true;

  var version = "admin-theme-20260923a";
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
