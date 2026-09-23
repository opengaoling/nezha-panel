(function () {
  var desktopCssId = 'geoip-desktop-layout-fix';
  var desktopCssHref = '/assets/geoip-desktop-layout-fix-20260613c.css?v=front-theme-20260617a';

  function isDesktopLayout() {
    return !document.documentElement.classList.contains('geoip-mobile-ua') && window.innerWidth >= 900;
  }

  function syncDesktopCss() {
    var existing = document.getElementById(desktopCssId);

    if (!isDesktopLayout()) {
      if (existing) {
        existing.parentNode.removeChild(existing);
      }
      document.documentElement.style.removeProperty('--geoip-desktop-name-col');
      return false;
    }

    if (!existing) {
      var link = document.createElement('link');
      link.id = desktopCssId;
      link.rel = 'stylesheet';
      link.href = desktopCssHref;
      document.head.appendChild(link);
    }

    return true;
  }

  function alignMetricsToOnlineCard() {
    if (!syncDesktopCss()) {
      return;
    }

    var onlineCard = document.querySelector('#root .server-overview > div:nth-child(2)');
    var row = document.querySelector('#root .server-card-list > *');
    if (!onlineCard || !row) {
      return;
    }

    var targetLeft = onlineCard.getBoundingClientRect().left;
    var rowLeft = row.getBoundingClientRect().left;
    var nameWidth = Math.round(targetLeft - rowLeft - 10);
    if (nameWidth >= 120 && nameWidth <= 520) {
      document.documentElement.style.setProperty('--geoip-desktop-name-col', nameWidth + 'px');
    }
  }

  function scheduleAlign() {
    window.requestAnimationFrame(alignMetricsToOnlineCard);
  }

  syncDesktopCss();

  for (var i = 0; i < 8; i += 1) {
    window.setTimeout(scheduleAlign, i * 250);
  }
  window.addEventListener('resize', scheduleAlign, { passive: true });
})();
