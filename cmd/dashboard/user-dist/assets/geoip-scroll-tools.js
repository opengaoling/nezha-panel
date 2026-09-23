(function () {
  if (document.getElementById("geoip-scroll-tools")) return;

  function scrollToEdge(top) {
    var scrollingElement = document.scrollingElement || document.documentElement;
    var target = top ? 0 : scrollingElement.scrollHeight;
    window.scrollTo({ top: target, behavior: "smooth" });
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
    return button;
  }

  function mount() {
    if (document.getElementById("geoip-scroll-tools")) return;
    var tools = document.createElement("div");
    tools.id = "geoip-scroll-tools";
    tools.className = "geoip-scroll-tools";
    tools.appendChild(makeButton("回到顶部", '<path d="m18 15-6-6-6 6"/><path d="M12 9v12"/><path d="M5 3h14"/>', true));
    tools.appendChild(makeButton("滚动到底部", '<path d="m6 9 6 6 6-6"/><path d="M12 15V3"/><path d="M5 21h14"/>', false));
    document.body.appendChild(tools);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mount, { once: true });
  } else {
    mount();
  }
})();
