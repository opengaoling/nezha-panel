(function () {
  if (window.__geoipFrontThemeInstalled) return;
  window.__geoipFrontThemeInstalled = true;

  // Enable OS/platform column in card view
  window.FixedTopServerName = true;

  var version = "front-theme-20260923a";
  var scripts = [
    "/assets/geoip-dashboard-link-fix-20260614.js",
    "/assets/geoip-auth-guard.js",
    "/assets/geoip-overview-status-highlight.js",
    "/assets/geoip-desktop-layout-loader-20260613c.js",
    "/assets/geoip-scroll-tools.js"
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
    document.addEventListener("DOMContentLoaded", loadScripts);
  } else {
    loadScripts();
  }
})();
