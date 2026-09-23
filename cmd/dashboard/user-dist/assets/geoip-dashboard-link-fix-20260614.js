(function () {
  if (window.__geoipDashboardLinkFixInstalled) return;
  window.__geoipDashboardLinkFixInstalled = true;

  function sameOriginUrl(path) {
    return new URL(path, window.location.origin).href;
  }

  function dashboardUrl() {
    return sameOriginUrl("/dashboard");
  }

  function isDashboardEntryUrl(url) {
    return url.origin === window.location.origin && (
      url.pathname === "/dashboard" ||
      url.pathname === "/dashboard/" ||
      url.pathname === "/dashboard/login"
    );
  }

  function isDashboardEntry(link) {
    if (!link || !link.href) return false;

    try {
      var url = new URL(link.href, window.location.href);
      return isDashboardEntryUrl(url);
    } catch (_e) {
      return false;
    }
  }

  function setLinkText(link, text) {
    var textTargets = [];
    for (var i = 0; i < link.childNodes.length; i += 1) {
      if (link.childNodes[i].nodeType === Node.TEXT_NODE && link.childNodes[i].nodeValue.trim()) {
        textTargets.push(link.childNodes[i]);
      }
    }

    if (textTargets.length) {
      textTargets[textTargets.length - 1].nodeValue = text;
      return;
    }

    var label = link.querySelector("span:not(.sr-only), p, div");
    if (label && label.textContent && /dashboard|login|后台|後台|登录|登錄|管理/i.test(label.textContent)) {
      label.textContent = text;
      return;
    }

    link.textContent = text;
  }

  function updateDashboardLinks() {
    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i += 1) {
      var link = links[i];
      if (!isDashboardEntry(link)) continue;

      link.href = dashboardUrl();
      setLinkText(link, "后台管理");
      link.setAttribute("data-geoip-dashboard-entry", "dashboard");
    }
  }

  function handleNavigationEvent(event) {
    var link = event.target && event.target.closest && event.target.closest("a[href]");

    if (!isDashboardEntry(link)) return;

    event.preventDefault();
    event.stopPropagation();
    window.location.assign(dashboardUrl());
  }

  function wrapHistoryMethod(methodName) {
    var nativeMethod = window.history && window.history[methodName];
    if (typeof nativeMethod !== "function") return;

    window.history[methodName] = function (_state, _title, url) {
      var result = nativeMethod.apply(this, arguments);

      if (url !== undefined) {
        try {
          var nextUrl = new URL(url, window.location.href);
          if (isDashboardEntryUrl(nextUrl)) {
            window.history.replaceState(null, "", dashboardUrl());
          }
        } catch (_e) {}
      }

      return result;
    };
  }

  document.addEventListener("pointerdown", handleNavigationEvent, true);
  document.addEventListener("touchend", handleNavigationEvent, true);
  document.addEventListener("click", handleNavigationEvent, true);
  wrapHistoryMethod("pushState");
  wrapHistoryMethod("replaceState");

  new MutationObserver(updateDashboardLinks).observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", updateDashboardLinks, { once: true });
  } else {
    updateDashboardLinks();
  }
})();
