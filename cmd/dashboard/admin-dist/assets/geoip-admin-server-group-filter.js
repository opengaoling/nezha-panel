(function () {
  "use strict";

  var STORAGE_KEY = "geoip-admin-server-group-filter";
  var STATUS_STORAGE_KEY = "geoip-admin-server-status-filter";
  var FACET_STORAGE_KEY = "geoip-admin-server-facet-filter";
  var FILTER_ID = "geoip-admin-server-group-filter";
  var ALL_VALUE = "__all__";
  var STATUS_ALL = "all";
  var STATUS_ONLINE = "online";
  var STATUS_OFFLINE = "offline";
  var FACET_ALL = "__all__";
  var FACET_UNKNOWN = "__unknown__";
  var savedFacets = {};
  try {
    savedFacets = JSON.parse(sessionStorage.getItem(FACET_STORAGE_KEY) || "{}");
  } catch (_) {
    sessionStorage.removeItem(FACET_STORAGE_KEY);
  }
  var state = {
    groups: null,
    serverStatus: null,
    serverFacets: null,
    serverStatusPromise: null,
    serverStatusRequestedAt: 0,
    selected: sessionStorage.getItem(STORAGE_KEY) || ALL_VALUE,
    selectedStatus: sessionStorage.getItem(STATUS_STORAGE_KEY) || STATUS_ALL,
    selectedFacets: {
      system: savedFacets.system || FACET_ALL,
      region: savedFacets.region || FACET_ALL,
      organization: savedFacets.organization || FACET_ALL
    },
    observer: null,
    applying: false,
    selectionGuardInstalled: false,
    selectionSyncTimer: null,
    selectionSyncing: false
  };

  function isServerPage() {
    var path = window.location.pathname.replace(/\/+$/, "");
    return path === "/dashboard";
  }

  function requestGroups() {
    if (state.groups) return Promise.resolve(state.groups);
    return fetch("/api/v1/server-group", {
      credentials: "same-origin",
      headers: { Accept: "application/json" }
    })
      .then(function (response) {
        if (!response.ok) throw new Error("server group request failed");
        return response.json();
      })
      .then(function (payload) {
        var groups = Array.isArray(payload && payload.data) ? payload.data : [];
        state.groups = groups
          .map(function (item) {
            var group = item.group || {};
            return {
              id: String(group.id || group.name || ""),
              name: group.name || "",
              servers: new Set((item.servers || []).map(function (id) { return String(id); }))
            };
          })
          .filter(function (group) { return group.id && group.name; });
        if (state.selected !== ALL_VALUE && !state.groups.some(function (group) { return group.id === state.selected; })) {
          state.selected = ALL_VALUE;
          sessionStorage.setItem(STORAGE_KEY, state.selected);
        }
        return state.groups;
      })
      .catch(function () {
        state.groups = [];
        return state.groups;
      });
  }

  function isOnline(server) {
    if (typeof server.online === "boolean") return server.online;
    if (!server.last_active) return false;
    var lastActive = new Date(server.last_active).getTime();
    if (!Number.isFinite(lastActive) || lastActive <= 0) return false;
    return Date.now() - lastActive < 35000;
  }

  function facetValue(value) {
    var normalized = String(value || "").trim();
    return normalized || FACET_UNKNOWN;
  }

  function requestServerStatus(force) {
    var now = Date.now();
    if (!force && state.serverStatus && now - state.serverStatusRequestedAt < 15000) {
      return Promise.resolve(state.serverStatus);
    }
    if (state.serverStatusPromise) return state.serverStatusPromise;

    state.serverStatusRequestedAt = now;
    state.serverStatusPromise = fetch("/api/v1/server", {
      credentials: "same-origin",
      headers: { Accept: "application/json" }
    })
      .then(function (response) {
        if (!response.ok) throw new Error("server status request failed");
        return response.json();
      })
      .then(function (payload) {
        var servers = Array.isArray(payload && payload.data) ? payload.data : [];
        var status = new Map();
        var facets = new Map();
        servers.forEach(function (server) {
          if (!server || !server.id) return;
          var id = String(server.id);
          status.set(id, isOnline(server));
          facets.set(id, {
            system: facetValue(server.host && server.host.platform),
            region: facetValue((server.geoip && server.geoip.country_code) || server.country_code),
            organization: facetValue((server.geoip && server.geoip.organization) || server.organization)
          });
        });
        state.serverStatus = status;
        state.serverFacets = facets;
        populateFacetControls();
        return status;
      })
      .catch(function () {
        state.serverStatus = state.serverStatus || new Map();
        return state.serverStatus;
      })
      .finally(function () {
        state.serverStatusPromise = null;
      });
    return state.serverStatusPromise;
  }

  function serverIdFromRow(row) {
    var cell = serverIdCellFromRow(row);
    return cell ? serverIdFromCell(cell) : "";
  }

  function serverIdFromCell(cell) {
    var text = (cell.textContent || "").trim();
    var match = text.match(/^(\d+)(?:\s*\(|\b)/);
    return match ? match[1] : "";
  }

  function serverIdCellFromRow(row) {
    var cells = Array.prototype.slice.call(row.querySelectorAll("td"));
    for (var i = 0; i < cells.length; i += 1) {
      if (serverIdFromCell(cells[i])) return cells[i];
    }
    return null;
  }

  function applyServerStatus() {
    if (!isServerPage() || !state.serverStatus) return;
    var rows = document.querySelectorAll("#root tbody tr");
    rows.forEach(function (row) {
      var cell = serverIdCellFromRow(row);
      if (!cell) return;
      var id = serverIdFromCell(cell);
      var online = state.serverStatus.get(id);
      var dot = cell.querySelector(":scope > .geoip-admin-server-status-dot");
      if (!dot) {
        dot = document.createElement("span");
        dot.className = "geoip-admin-server-status-dot";
        dot.setAttribute("aria-hidden", "true");
        cell.insertBefore(dot, cell.firstChild);
      }
      var label = online === true ? "在线" : online === false ? "离线" : "未知";
      dot.setAttribute("data-status", online === true ? "online" : online === false ? "offline" : "unknown");
      dot.title = label;
      cell.setAttribute("data-geoip-admin-server-status", label);
    });
  }

  function selectedGroup() {
    if (state.selected === ALL_VALUE) return null;
    return (state.groups || []).find(function (group) { return group.id === state.selected; }) || null;
  }

  function matchesFacets(id) {
    var facets = id && state.serverFacets ? state.serverFacets.get(id) : null;
    return ["system", "region", "organization"].every(function (key) {
      return state.selectedFacets[key] === FACET_ALL || (facets && facets[key] === state.selectedFacets[key]);
    });
  }

  function isFilterHidden(row) {
    return row.getAttribute("data-geoip-group-filter-hidden") === "true" ||
      row.getAttribute("data-geoip-status-filter-hidden") === "true" ||
      row.getAttribute("data-geoip-facet-filter-hidden") === "true";
  }

  function serverRows() {
    return Array.prototype.filter.call(document.querySelectorAll("#root tbody tr"), function (row) {
      return !!serverIdFromRow(row);
    });
  }

  function rowCheckbox(row) {
    return row.querySelector('button[role="checkbox"][aria-label="Select row"], [role="checkbox"][aria-label="Select row"], input[type="checkbox"][aria-label="Select row"]');
  }

  function checkboxChecked(control) {
    if (!control) return false;
    if (control.type === "checkbox") return !!control.checked;
    return control.getAttribute("aria-checked") === "true" || control.getAttribute("data-state") === "checked";
  }

  function clickCheckboxTo(control, checked) {
    if (!control || checkboxChecked(control) === checked || control.disabled || control.getAttribute("aria-disabled") === "true") return;
    control.click();
  }

  function selectAllCheckbox() {
    return document.querySelector('#root thead button[role="checkbox"][aria-label="Select all"], #root thead [role="checkbox"][aria-label="Select all"], #root thead input[type="checkbox"][aria-label="Select all"]');
  }

  function setCheckboxPresentation(control, stateName) {
    if (!control) return;
    var ariaChecked = stateName === "checked" ? "true" : stateName === "indeterminate" ? "mixed" : "false";
    if (control.type === "checkbox") {
      control.checked = stateName === "checked";
      control.indeterminate = stateName === "indeterminate";
    }
    control.setAttribute("aria-checked", ariaChecked);
    control.setAttribute("data-state", stateName);
    control.querySelectorAll("[data-state]").forEach(function (node) {
      node.setAttribute("data-state", stateName);
    });
  }

  function syncSelectAllCheckbox() {
    if (!isServerPage()) return;
    var control = selectAllCheckbox();
    if (!control) return;
    var controls = serverRows()
      .filter(function (row) { return !isFilterHidden(row); })
      .map(rowCheckbox)
      .filter(Boolean);
    if (!controls.length) {
      setCheckboxPresentation(control, "unchecked");
      return;
    }
    var selectedCount = controls.filter(checkboxChecked).length;
    setCheckboxPresentation(
      control,
      selectedCount === controls.length ? "checked" : selectedCount > 0 ? "indeterminate" : "unchecked"
    );
  }

  function pruneHiddenSelections() {
    if (!isServerPage() || state.selectionSyncing) return;
    state.selectionSyncing = true;
    try {
      serverRows().forEach(function (row) {
        if (!isFilterHidden(row)) return;
        clickCheckboxTo(rowCheckbox(row), false);
      });
    } finally {
      state.selectionSyncing = false;
    }
    window.setTimeout(syncSelectAllCheckbox, 0);
  }

  function scheduleSelectionSync() {
    window.clearTimeout(state.selectionSyncTimer);
    state.selectionSyncTimer = window.setTimeout(function () {
      pruneHiddenSelections();
      syncSelectAllCheckbox();
    }, 0);
  }

  function toggleVisibleSelection() {
    if (!isServerPage() || state.selectionSyncing) return;
    state.selectionSyncing = true;
    try {
      var visibleControls = serverRows()
        .filter(function (row) { return !isFilterHidden(row); })
        .map(rowCheckbox)
        .filter(Boolean);
      var hiddenControls = serverRows()
        .filter(isFilterHidden)
        .map(rowCheckbox)
        .filter(Boolean);
      var shouldSelectVisible = visibleControls.length > 0 && !visibleControls.every(checkboxChecked);
      visibleControls.forEach(function (control) { clickCheckboxTo(control, shouldSelectVisible); });
      hiddenControls.forEach(function (control) { clickCheckboxTo(control, false); });
    } finally {
      state.selectionSyncing = false;
    }
    window.setTimeout(syncSelectAllCheckbox, 0);
  }

  function checkboxFromEventTarget(target) {
    return target && target.closest ? target.closest('button[role="checkbox"], [role="checkbox"], input[type="checkbox"]') : null;
  }

  function isSelectAllCheckbox(control) {
    return !!control &&
      control.closest("#root thead") &&
      (control.getAttribute("aria-label") || "").toLowerCase() === "select all";
  }

  function handleSelectAllClick(event) {
    var control = checkboxFromEventTarget(event.target);
    if (!isSelectAllCheckbox(control)) return;
    event.preventDefault();
    event.stopPropagation();
    if (event.stopImmediatePropagation) event.stopImmediatePropagation();
    toggleVisibleSelection();
  }

  function handleSelectAllKeydown(event) {
    if (event.key !== " " && event.key !== "Enter") return;
    var control = checkboxFromEventTarget(event.target);
    if (!isSelectAllCheckbox(control)) return;
    event.preventDefault();
    event.stopPropagation();
    if (event.stopImmediatePropagation) event.stopImmediatePropagation();
    toggleVisibleSelection();
  }

  function installSelectionGuard() {
    if (state.selectionGuardInstalled) return;
    document.addEventListener("click", handleSelectAllClick, true);
    document.addEventListener("keydown", handleSelectAllKeydown, true);
    state.selectionGuardInstalled = true;
  }

  function applyFilter() {
    if (!isServerPage() || state.applying) return;
    state.applying = true;
    try {
      var group = selectedGroup();
      var rows = document.querySelectorAll("#root tbody tr");
      rows.forEach(function (row) {
        var id = serverIdFromRow(row);
        var shouldHideForGroup = !!(id && group && !group.servers.has(id));
        var isGroupHidden = row.getAttribute("data-geoip-group-filter-hidden") === "true";
        if (shouldHideForGroup && !isGroupHidden) row.setAttribute("data-geoip-group-filter-hidden", "true");
        if (!shouldHideForGroup && isGroupHidden) row.removeAttribute("data-geoip-group-filter-hidden");

        var online = id && state.serverStatus ? state.serverStatus.get(id) : undefined;
        var shouldHideForStatus = state.selectedStatus === STATUS_ONLINE
          ? online !== true
          : state.selectedStatus === STATUS_OFFLINE
            ? online !== false
            : false;
        var isStatusHidden = row.getAttribute("data-geoip-status-filter-hidden") === "true";
        if (shouldHideForStatus && !isStatusHidden) row.setAttribute("data-geoip-status-filter-hidden", "true");
        if (!shouldHideForStatus && isStatusHidden) row.removeAttribute("data-geoip-status-filter-hidden");

        var shouldHideForFacet = !!id && !matchesFacets(id);
        var isFacetHidden = row.getAttribute("data-geoip-facet-filter-hidden") === "true";
        if (shouldHideForFacet && !isFacetHidden) row.setAttribute("data-geoip-facet-filter-hidden", "true");
        if (!shouldHideForFacet && isFacetHidden) row.removeAttribute("data-geoip-facet-filter-hidden");
      });
      updateButtons();
      applyServerStatus();
      scheduleSelectionSync();
    } finally {
      state.applying = false;
    }
  }

  function updateButtons() {
    var root = document.getElementById(FILTER_ID);
    if (!root) return;
    root.querySelectorAll("button[data-group-id]").forEach(function (button) {
      button.setAttribute("aria-pressed", button.getAttribute("data-group-id") === state.selected ? "true" : "false");
    });
    root.querySelectorAll("button[data-status-filter]").forEach(function (button) {
      button.setAttribute("aria-pressed", button.getAttribute("data-status-filter") === state.selectedStatus ? "true" : "false");
    });
  }

  function makeButton(group) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "geoip-admin-server-group-filter__button";
    button.setAttribute("data-group-id", group.id);
    button.setAttribute("aria-pressed", group.id === state.selected ? "true" : "false");
    button.title = group.name;
    button.textContent = group.name;
    button.addEventListener("click", function () {
      state.selected = group.id;
      sessionStorage.setItem(STORAGE_KEY, state.selected);
      applyFilter();
    });
    return button;
  }

  function makeStatusButton(value, label) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "geoip-admin-server-group-filter__button";
    button.setAttribute("data-status-filter", value);
    button.setAttribute("aria-pressed", value === state.selectedStatus ? "true" : "false");
    button.textContent = label;
    button.addEventListener("click", function () {
      state.selectedStatus = value;
      sessionStorage.setItem(STATUS_STORAGE_KEY, value);
      applyFilter();
    });
    return button;
  }

  function facetLabel(value) {
    return value === FACET_UNKNOWN ? "未知" : value;
  }

  function facetOptions(key) {
    var values = new Set();
    if (state.serverFacets) {
      state.serverFacets.forEach(function (facets) { values.add(facets[key]); });
    }
    return Array.from(values).sort(function (left, right) {
      if (left === FACET_UNKNOWN) return 1;
      if (right === FACET_UNKNOWN) return -1;
      return left.localeCompare(right, "zh-CN", { sensitivity: "base" });
    });
  }

  function populateFacetControls() {
    var root = document.getElementById(FILTER_ID);
    if (!root) return;
    root.querySelectorAll("select[data-facet-key]").forEach(function (select) {
      var key = select.getAttribute("data-facet-key");
      var selected = state.selectedFacets[key] || FACET_ALL;
      select.replaceChildren(new Option("全部", FACET_ALL));
      facetOptions(key).forEach(function (value) { select.add(new Option(facetLabel(value), value)); });
      if (!Array.from(select.options).some(function (option) { return option.value === selected; })) {
        selected = FACET_ALL;
        state.selectedFacets[key] = selected;
      }
      select.value = selected;
    });
    sessionStorage.setItem(FACET_STORAGE_KEY, JSON.stringify(state.selectedFacets));
  }

  function makeFacetControl(key, label) {
    var control = document.createElement("label");
    control.className = "geoip-admin-server-group-filter__facet";
    var text = document.createElement("span");
    text.textContent = label;
    var select = document.createElement("select");
    select.setAttribute("data-facet-key", key);
    select.setAttribute("aria-label", label + "筛选");
    select.addEventListener("change", function () {
      state.selectedFacets[key] = select.value;
      sessionStorage.setItem(FACET_STORAGE_KEY, JSON.stringify(state.selectedFacets));
      applyFilter();
    });
    control.appendChild(text);
    control.appendChild(select);
    return control;
  }

  function mountFilter() {
    if (!isServerPage()) {
      var existing = document.getElementById(FILTER_ID);
      if (existing) existing.remove();
      return;
    }

    requestGroups().then(function (groups) {
      if (!isServerPage() || document.getElementById(FILTER_ID)) {
        applyFilter();
        return;
      }

      var page = document.querySelector("#root h1");
      if (!page || !/Server|服务器/.test(page.textContent || "")) return;
      var toolbar = page.closest("div");
      if (!toolbar || !toolbar.parentElement) return;

      var wrapper = document.createElement("section");
      wrapper.id = FILTER_ID;
      wrapper.className = "geoip-admin-server-group-filter";

      var label = document.createElement("span");
      label.className = "geoip-admin-server-group-filter__label";
      label.textContent = "服务器分组";

      var list = document.createElement("div");
      list.className = "geoip-admin-server-group-filter__list";
      list.appendChild(makeButton({ id: ALL_VALUE, name: "全部服务器", servers: new Set() }));
      groups.forEach(function (group) { list.appendChild(makeButton(group)); });

      wrapper.appendChild(label);
      wrapper.appendChild(list);

      var statusGroup = document.createElement("div");
      statusGroup.className = "geoip-admin-server-group-filter__status";
      var statusLabel = document.createElement("span");
      statusLabel.className = "geoip-admin-server-group-filter__label";
      statusLabel.textContent = "在线状态";
      var statusList = document.createElement("div");
      statusList.className = "geoip-admin-server-group-filter__status-list";
      statusList.appendChild(makeStatusButton(STATUS_ALL, "全部"));
      statusList.appendChild(makeStatusButton(STATUS_ONLINE, "在线服务器"));
      statusList.appendChild(makeStatusButton(STATUS_OFFLINE, "离线服务器"));
      statusGroup.appendChild(statusLabel);
      statusGroup.appendChild(statusList);
      wrapper.appendChild(statusGroup);

      var facets = document.createElement("div");
      facets.className = "geoip-admin-server-group-filter__facets";
      facets.appendChild(makeFacetControl("system", "系统"));
      facets.appendChild(makeFacetControl("region", "地区"));
      facets.appendChild(makeFacetControl("organization", "组织"));
      wrapper.appendChild(facets);
      toolbar.parentElement.insertBefore(wrapper, toolbar.nextSibling);
      populateFacetControls();
      requestServerStatus(false).then(applyFilter);
    });
  }

  function scheduleMount() {
    window.clearTimeout(scheduleMount.timer);
    scheduleMount.timer = window.setTimeout(function () {
      mountFilter();
      applyFilter();
      requestServerStatus(false).then(applyServerStatus);
    }, 80);
  }

  function patchHistory(name) {
    var original = history[name];
    history[name] = function () {
      var result = original.apply(this, arguments);
      scheduleMount();
      return result;
    };
  }

  function boot() {
    installSelectionGuard();
    patchHistory("pushState");
    patchHistory("replaceState");
    window.addEventListener("popstate", scheduleMount);
    state.observer = new MutationObserver(scheduleMount);
    state.observer.observe(document.documentElement, { childList: true, subtree: true });
    scheduleMount();
    window.setInterval(function () {
      if (isServerPage()) requestServerStatus(true).then(applyFilter);
    }, 20000);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot, { once: true });
  } else {
    boot();
  }
})();
