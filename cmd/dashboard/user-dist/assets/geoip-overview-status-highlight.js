(function () {
  if (window.__geoipOverviewStatusHighlightInstalled) return;
  window.__geoipOverviewStatusHighlightInstalled = true;

  var selectedClass = "geoip-overview-status-selected";
  var styleId = "geoip-overview-status-highlight-style";
  var currentStatus = "online";
  var defaultApplied = false;
  var syncing = false;
  var lastUserSelectedAt = 0;
  var labels = {
    all: ["服务器总数", "全部服务器", "總伺服器", "Total Servers"],
    online: ["在线服务器", "線上伺服器", "Online Servers"],
    offline: ["离线服务器", "離線伺服器", "Offline Servers"]
  };

  function ensureStyle() {
    if (document.getElementById(styleId)) return;
    var style = document.createElement("style");
    style.id = styleId;
    style.textContent = [
      "." + selectedClass + " {",
      "  border-color: rgb(34 197 94) !important;",
      "  box-shadow: 0 0 0 2px rgba(34, 197, 94, 0.95), 0 0 0 5px rgba(34, 197, 94, 0.14) !important;",
      "}",
      ".dark ." + selectedClass + " {",
      "  border-color: rgb(22 163 74) !important;",
      "  box-shadow: 0 0 0 2px rgba(34, 197, 94, 0.95), 0 0 0 5px rgba(34, 197, 94, 0.2) !important;",
      "}",
      "." + selectedClass + ":focus-visible {",
      "  outline: 2px solid rgba(34, 197, 94, 0.95);",
      "  outline-offset: 2px;",
      "}"
    ].join("\n");
    document.head.appendChild(style);
  }

  function isVisible(element) {
    if (!element) return false;
    var rect = element.getBoundingClientRect();
    var style = window.getComputedStyle(element);
    return rect.width > 1 && rect.height > 1 && style.display !== "none" && style.visibility !== "hidden";
  }

  function normalizedText(element) {
    return (element && element.innerText ? element.innerText : "").replace(/\s+/g, " ").trim();
  }

  function hasLabel(element, status) {
    var text = normalizedText(element);
    return labels[status].some(function (label) {
      return text.indexOf(label) !== -1;
    });
  }

  function clickableCard(element) {
    var current = element;
    var root = document.getElementById("root");
    while (current && current !== root) {
      if (current.matches && (current.matches("button, [role='button'], a") || current.onclick || current.tabIndex >= 0)) {
        return current;
      }
      var rect = current.getBoundingClientRect();
      if (rect.width >= 80 && rect.height >= 40 && /\bborder\b|\brounded\b|\bshadow\b|\bcard\b/.test(current.className || "")) {
        return current;
      }
      current = current.parentElement;
    }
    return element;
  }

  function cardsFromOverview() {
    var blocks = Array.prototype.slice.call(document.querySelectorAll("#root .server-overview"));
    for (var i = 0; i < blocks.length; i += 1) {
      if (!isVisible(blocks[i])) continue;
      var children = Array.prototype.slice.call(blocks[i].children).filter(isVisible).slice(0, 3);
      if (children.length >= 3 && hasLabel(children[0], "all") && hasLabel(children[1], "online") && hasLabel(children[2], "offline")) {
        return children;
      }
    }
    return [];
  }

  function cardByLabel(status) {
    var nodes = Array.prototype.slice.call(document.querySelectorAll("#root *")).filter(function (element) {
      return isVisible(element) && hasLabel(element, status);
    });
    nodes.sort(function (a, b) {
      return normalizedText(a).length - normalizedText(b).length;
    });
    return nodes.length ? clickableCard(nodes[0]) : null;
  }

  function overviewCards() {
    var cards = cardsFromOverview();
    if (cards.length >= 3) return cards;

    cards = [cardByLabel("all"), cardByLabel("online"), cardByLabel("offline")];
    if (cards.every(Boolean)) return cards;
    return [];
  }

  function statusIndex(status) {
    if (status === "online") return 1;
    if (status === "offline") return 2;
    return 0;
  }

  function detectReactStatus(cards) {
    if (cards[0] && cards[0].classList.contains("ring-2")) return "all";
    if (cards[1] && cards[1].classList.contains("ring-2")) return "online";
    if (cards[2] && cards[2].classList.contains("ring-2")) return "offline";
    return null;
  }

  function applySelected(status) {
    ensureStyle();
    var cards = overviewCards();
    if (cards.length < 3) return;

    currentStatus = status || detectReactStatus(cards) || currentStatus;
    var activeIndex = statusIndex(currentStatus);
    cards.forEach(function (card, index) {
      card.classList.toggle(selectedClass, index === activeIndex);
      card.setAttribute("aria-pressed", index === activeIndex ? "true" : "false");
    });
  }

  function syncFromDom() {
    if (syncing) return;
    syncing = true;
    window.requestAnimationFrame(function () {
      syncing = false;
      var cards = overviewCards();
      if (cards.length < 3) return;
      var detected = detectReactStatus(cards);
      var recentlyClicked = Date.now() - lastUserSelectedAt < 1200;
      applySelected(recentlyClicked ? currentStatus : detected || currentStatus);
    });
  }

  function bindClicks() {
    var cards = overviewCards();
    if (cards.length < 3) return false;
    ["all", "online", "offline"].forEach(function (status, index) {
      if (cards[index].__geoipOverviewStatusBound) return;
      cards[index].__geoipOverviewStatusBound = true;
      cards[index].addEventListener("click", function () {
        lastUserSelectedAt = Date.now();
        applySelected(status);
        window.setTimeout(syncFromDom, 0);
      });
    });
    if (!defaultApplied) {
      defaultApplied = true;
      window.setTimeout(function () {
        var nextCards = overviewCards();
        if (nextCards[1]) {
          nextCards[1].click();
        } else {
          applySelected("online");
        }
      }, 0);
      return true;
    }
    applySelected(currentStatus);
    return true;
  }

  function start() {
    ensureStyle();
    bindClicks();
    var root = document.getElementById("root");
    if (!root) return;
    var observer = new MutationObserver(function () {
      bindClicks();
      syncFromDom();
    });
    observer.observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
