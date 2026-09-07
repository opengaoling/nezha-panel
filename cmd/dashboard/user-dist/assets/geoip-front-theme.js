(function () {
  if (window.__geoipFrontThemeInstalled) return;
  window.__geoipFrontThemeInstalled = true;

  var version = "front-theme-20260624a";
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

  function appendScript(src) {
    var script = document.createElement("script");
    script.src = versioned(src);
    script.async = false;
    document.head.appendChild(script);
  }

  if (document.readyState === "loading") {
    document.write(scripts.map(function (src) {
      return '<script src="' + versioned(src) + '"><\/script>';
    }).join(""));
    return;
  }

  scripts.forEach(appendScript);
})();
