(function () {
  if (window.__customFrontThemeInstalled) return;
  window.__customFrontThemeInstalled = true;

  // Enable OS/platform column in card view
  window.FixedTopServerName = true;

  var version = "front-theme-20260924a";
  var scripts = [
    "/assets/custom-dashboard-link-fix-20260614.js",
    "/assets/custom-auth-guard.js",
    "/assets/custom-overview-status-highlight.js",
    "/assets/custom-desktop-layout-loader-20260613c.js",
    "/assets/custom-scroll-tools.js"
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
