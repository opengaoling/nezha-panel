(function () {
  function getViewportWidth() {
    return document.documentElement.clientWidth || window.innerWidth || 0;
  }

  function applyToolStyles(tools) {
    var viewportWidth = getViewportWidth();
    var buttonWidth = 40;
    var rightGap = 14;
    var left = Math.max(8, viewportWidth - buttonWidth - rightGap);

    tools.style.setProperty("position", "fixed", "important");
    tools.style.setProperty("left", left + "px", "important");
    tools.style.setProperty("right", "auto", "important");
    tools.style.setProperty("bottom", "max(70px, calc(env(safe-area-inset-bottom) + 16px))", "important");
    tools.style.setProperty("z-index", "2147483647", "important");
    tools.style.setProperty("display", "flex", "important");
    tools.style.setProperty("flex-direction", "column", "important");
    tools.style.setProperty("gap", "8px", "important");
    tools.style.setProperty("visibility", "visible", "important");
    tools.style.setProperty("opacity", "1", "important");
    tools.style.setProperty("pointer-events", "auto", "important");
  }

  function applyButtonStyles(button) {
    button.style.setProperty("display", "inline-flex", "important");
    button.style.setProperty("width", "40px", "important");
    button.style.setProperty("height", "40px", "important");
    button.style.setProperty("min-width", "40px", "important");
    button.style.setProperty("min-height", "40px", "important");
    button.style.setProperty("align-items", "center", "important");
    button.style.setProperty("justify-content", "center", "important");
    button.style.setProperty("visibility", "visible", "important");
    button.style.setProperty("opacity", "1", "important");
    button.style.setProperty("pointer-events", "auto", "important");
  }

  function canScroll(element) {
    if (!element) return false;
    return element.scrollHeight > element.clientHeight + 2 || element.scrollWidth > element.clientWidth + 2;
  }

  function getScrollableElements() {
    var seen = [];
    var elements = [];
    var root = document.scrollingElement || document.documentElement;

    function add(element) {
      if (!element || seen.indexOf(element) !== -1 || !canScroll(element)) return;
      seen.push(element);
      elements.push(element);
    }

    add(root);
    add(document.documentElement);
    add(document.body);

    Array.prototype.forEach.call(document.querySelectorAll("*"), function (element) {
      var style = window.getComputedStyle(element);
      var overflowY = style.overflowY;
      var overflowX = style.overflowX;
      var canScrollY = /(auto|scroll|overlay)/.test(overflowY) && element.scrollHeight > element.clientHeight + 2;
      var canScrollX = /(auto|scroll|overlay)/.test(overflowX) && element.scrollWidth > element.clientWidth + 2;

      if (canScrollY || canScrollX) {
        add(element);
      }
    });

    return elements;
  }

  function scrollElementToEdge(element, top) {
    var scrollTop = top ? 0 : Math.max(0, element.scrollHeight - element.clientHeight);

    if (typeof element.scrollTo === "function") {
      element.scrollTo({ top: scrollTop, left: element.scrollLeft, behavior: "smooth" });
    } else {
      element.scrollTop = scrollTop;
    }
  }

  function scrollToEdge(top) {
    var target = top ? 0 : Math.max(
      document.documentElement.scrollHeight,
      document.body ? document.body.scrollHeight : 0
    );

    window.scrollTo({ top: target, behavior: "smooth" });
    getScrollableElements().forEach(function (element) {
      scrollElementToEdge(element, top);
    });
  }

  function makeButton(label, path, top) {
    var button = document.createElement("button");
    button.type = "button";
    button.setAttribute("aria-label", label);
    button.title = label;
    button.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      path +
      "</svg>";
    button.addEventListener("click", function () {
      scrollToEdge(top);
    });
    applyButtonStyles(button);
    return button;
  }

  function mount() {
    var tools = document.getElementById("geoip-scroll-tools");
    if (!tools) {
      tools = document.createElement("div");
      tools.id = "geoip-scroll-tools";
      tools.className = "geoip-scroll-tools";
      tools.appendChild(makeButton("回到顶部", '<path d="m18 15-6-6-6 6"/><path d="M12 9v12"/><path d="M5 3h14"/>', true));
      tools.appendChild(makeButton("滚动到底部", '<path d="m6 9 6 6 6-6"/><path d="M12 15V3"/><path d="M5 21h14"/>', false));
      document.body.appendChild(tools);
    }
    applyToolStyles(tools);
    Array.prototype.forEach.call(tools.querySelectorAll("button"), applyButtonStyles);
  }

  function scheduleMount() {
    mount();
    window.setTimeout(mount, 250);
    window.setTimeout(mount, 1000);
    window.setTimeout(mount, 2500);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", scheduleMount, { once: true });
  } else {
    scheduleMount();
  }

  window.addEventListener("load", scheduleMount, { once: true });
  window.addEventListener("resize", mount);
  window.addEventListener("orientationchange", scheduleMount);

  new MutationObserver(function () {
    mount();
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
