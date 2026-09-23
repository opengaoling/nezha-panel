(function () {
  "use strict";

  var FILTER_ID = "geoip-front-server-filter";
  var STORAGE_KEY = "geoip-front-server-facet-filter";
  var ALL_VALUE = "__all__";
  var UNKNOWN_VALUE = "__unknown__";
  var state = {
    servers: [],
    serverCache: new Map(),
    byId: new Map(),
    byName: new Map(),
    selected: loadSelected(),
    applying: false
  };

  function loadSelected() {
    try {
      var saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY) || "{}");
      return {
        system: saved.system || ALL_VALUE,
        region: saved.region || ALL_VALUE,
        organization: saved.organization || ALL_VALUE
      };
    } catch (_) {
      sessionStorage.removeItem(STORAGE_KEY);
      return { system: ALL_VALUE, region: ALL_VALUE, organization: ALL_VALUE };
    }
  }

  function facetValue(value) {
    var normalized = String(value || "").trim();
    return normalized || UNKNOWN_VALUE;
  }

  function normalizeServer(server) {
    return {
      id: String(server.id || ""),
      name: String(server.name || "").trim(),
      system: facetValue((server.host && server.host.platform) || server.platform),
      region: facetValue(server.country_code),
      organization: facetValue(server.organization)
    };
  }

  function capturePayload(raw) {
    try {
      var payload = JSON.parse(raw);
      if (!payload || !Array.isArray(payload.servers)) return;
      state.servers = payload.servers.map(function (server) {
        var id = String(server.id || "");
        var cached = state.serverCache.get(id) || {};
        var merged = Object.assign({}, cached, server, {
          host: Object.assign({}, cached.host || {}, server.host || {})
        });
        state.serverCache.set(id, merged);
        return normalizeServer(merged);
      }).filter(function (server) { return server.id && server.name; });
      state.byId = new Map(state.servers.map(function (server) { return [server.id, server]; }));
      state.byName = new Map();
      state.servers.forEach(function (server) {
        var matches = state.byName.get(server.name) || [];
        matches.push(server);
        state.byName.set(server.name, matches);
      });
      populateControls();
      scheduleApply();
    } catch (_) {
      return;
    }
  }

  function syncFromAppCache() {
    var appCache = window.__geoipStaticServerCache;
    if (!(appCache instanceof Map) || appCache.size === 0) return;
    appCache.forEach(function (server, id) {
      var key = String(id || (server && server.id) || "");
      if (!key || !server) return;
      var cached = state.serverCache.get(key) || {};
      state.serverCache.set(key, Object.assign({}, cached, server, {
        id: key,
        host: Object.assign({}, cached.host || {}, server.host || {})
      }));
    });
    state.servers = Array.from(state.serverCache.values())
      .map(normalizeServer)
      .filter(function (server) { return server.id && server.name; });
    state.byId = new Map(state.servers.map(function (server) { return [server.id, server]; }));
    state.byName = new Map();
    state.servers.forEach(function (server) {
      var matches = state.byName.get(server.name) || [];
      matches.push(server);
      state.byName.set(server.name, matches);
    });
    populateControls();
  }

  function trackSocket(socket, url) {
    if (String(url || "").indexOf("/api/v1/ws/server") === -1) return socket;
    socket.addEventListener("message", function (event) {
      if (typeof event.data === "string") {
        capturePayload(event.data);
      } else if (event.data && typeof event.data.text === "function") {
        event.data.text().then(capturePayload).catch(function () {});
      }
    });
    return socket;
  }

  function installWebSocketTracker() {
    var NativeWebSocket = window.WebSocket;
    if (!NativeWebSocket || NativeWebSocket.__geoipFrontFilterWrapped) return;
    function TrackedWebSocket(url, protocols) {
      var socket = protocols === undefined
        ? new NativeWebSocket(url)
        : new NativeWebSocket(url, protocols);
      return trackSocket(socket, url);
    }
    Object.setPrototypeOf(TrackedWebSocket, NativeWebSocket);
    TrackedWebSocket.prototype = NativeWebSocket.prototype;
    TrackedWebSocket.__geoipFrontFilterWrapped = true;
    window.WebSocket = TrackedWebSocket;
  }

  function isHomePage() {
    return window.location.pathname === "/";
  }

  function facetLabel(value) {
    return value === UNKNOWN_VALUE ? "未知" : value;
  }

  function valuesFor(key) {
    var values = new Set();
    state.servers.forEach(function (server) { values.add(server[key]); });
    return Array.from(values).sort(function (left, right) {
      if (left === UNKNOWN_VALUE) return 1;
      if (right === UNKNOWN_VALUE) return -1;
      return left.localeCompare(right, "zh-CN", { sensitivity: "base" });
    });
  }

  function populateControls() {
    var root = document.getElementById(FILTER_ID);
    if (!root) return;
    root.querySelectorAll("select[data-facet-key]").forEach(function (select) {
      var key = select.getAttribute("data-facet-key");
      var selected = state.selected[key] || ALL_VALUE;
      select.replaceChildren(new Option("全部", ALL_VALUE));
      valuesFor(key).forEach(function (value) { select.add(new Option(facetLabel(value), value)); });
      if (!Array.from(select.options).some(function (option) { return option.value === selected; })) {
        selected = ALL_VALUE;
        state.selected[key] = selected;
      }
      select.value = selected;
    });
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(state.selected));
  }

  function makeControl(key, label) {
    var control = document.createElement("label");
    control.className = "geoip-front-server-filter__control";
    var text = document.createElement("span");
    text.textContent = label;
    var select = document.createElement("select");
    select.setAttribute("data-facet-key", key);
    select.setAttribute("aria-label", label + "筛选");
    select.addEventListener("change", function () {
      state.selected[key] = select.value;
      sessionStorage.setItem(STORAGE_KEY, JSON.stringify(state.selected));
      applyFilter();
    });
    control.appendChild(text);
    control.appendChild(select);
    return control;
  }

  function mountFilter() {
    var existing = document.getElementById(FILTER_ID);
    if (!isHomePage()) {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;
    var controls = document.querySelector("#root .server-overview-controls");
    if (!controls || !controls.parentElement) return;
    var filter = document.createElement("section");
    filter.id = FILTER_ID;
    filter.className = "geoip-front-server-filter";
    var title = document.createElement("span");
    title.className = "geoip-front-server-filter__title";
    title.textContent = "筛选";
    filter.appendChild(title);
    filter.appendChild(makeControl("system", "系统"));
    filter.appendChild(makeControl("region", "地区"));
    filter.appendChild(makeControl("organization", "组织"));
    controls.parentElement.insertBefore(filter, controls.nextSibling);
    populateControls();
  }

  function serverMatches(server) {
    return ["system", "region", "organization"].every(function (key) {
      return state.selected[key] === ALL_VALUE || server[key] === state.selected[key];
    });
  }

  function cardName(card) {
    var name = card.querySelector("p[title]");
    return name ? String(name.getAttribute("title") || "").trim() : "";
  }

  function applyFilter() {
    if (!isHomePage() || state.applying) return;
    state.applying = true;
    try {
      mountFilter();
      syncFromAppCache();
      var hiddenCount = 0;
      var matchedCount = 0;
      document.querySelectorAll("#root .server-card-list > *, #root .server-inline-list > *").forEach(function (card) {
        var serverId = String(card.getAttribute("data-server-id") || "");
        var exactServer = state.byId.get(serverId);
        var candidates = exactServer ? [exactServer] : (state.byName.get(cardName(card)) || []);
        var hidden = candidates.length > 0 && !candidates.some(serverMatches);
        if (candidates.length > 0) matchedCount += 1;
        if (hidden) {
          hiddenCount += 1;
          card.hidden = true;
          card.setAttribute("data-geoip-front-filter-hidden", "true");
          card.style.setProperty("display", "none", "important");
        } else {
          card.hidden = false;
          card.removeAttribute("data-geoip-front-filter-hidden");
          card.style.removeProperty("display");
        }
      });
      var filter = document.getElementById(FILTER_ID);
      if (filter) {
        filter.setAttribute("data-matched-cards", String(matchedCount));
        filter.setAttribute("data-hidden-cards", String(hiddenCount));
      }
    } finally {
      state.applying = false;
    }
  }

  function scheduleApply() {
    window.clearTimeout(scheduleApply.timer);
    scheduleApply.timer = window.setTimeout(applyFilter, 60);
  }

  function boot() {
    new MutationObserver(scheduleApply).observe(document.documentElement, { childList: true, subtree: true });
    window.addEventListener("popstate", scheduleApply);
    scheduleApply();
  }

  installWebSocketTracker();
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot, { once: true });
  else boot();
})();
