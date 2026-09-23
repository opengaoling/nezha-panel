(function () {
  "use strict";

  // 在后台"编辑服务器"对话框中注入"服务器分组"多选区。
  // 保存服务器成功后，自动 PATCH 对应的 server-group 关系（增删成员）。
  // 仅依赖 /api/v1/server-group 与 /api/v1/server/{id} 既有接口，无后端改动。

  // 注入样式：限制编辑服务器对话框内 textarea 的默认高度
  var style = document.createElement("style");
  style.textContent = '[role="dialog"] form textarea[rows="10"]{min-height:40px !important;height:60px !important;max-height:100px}';
  document.head.appendChild(style);

  if (window.__customServerEditGroupInstalled) return;
  window.__customServerEditGroupInstalled = true;

  var FIELD_ATTR = "data-custom-edit-server-groups";
  var FORM_ATTR = "data-custom-edit-server-form";
  var CHECK_CLASS = "custom-edit-group-checkbox";

  var groupsCache = null;
  var groupsPromise = null;
  var serversCache = null;
  var serversPromise = null;
  var pendingByServer = {};
  var fetchPatched = false;

  function isDashboard() {
    var path = window.location.pathname.replace(/\/+$/, "");
    return /(?:^|\/)dashboard(?:\/|$)/.test(path);
  }

  function cookieValue(name) {
    var prefix = name + "=";
    var parts = document.cookie ? document.cookie.split("; ") : [];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].indexOf(prefix) === 0) return decodeURIComponent(parts[i].slice(prefix.length));
    }
    return "";
  }

  function requestHeaders() {
    var h = { "Content-Type": "application/json" };
    var csrf = cookieValue("nz-csrf");
    if (csrf) h["X-CSRF-Token"] = csrf;
    return h;
  }

  function loadGroups(force) {
    if (!force && groupsCache) return Promise.resolve(groupsCache);
    if (!force && groupsPromise) return groupsPromise;
    groupsPromise = fetch("/api/v1/server-group", { credentials: "same-origin", headers: { Accept: "application/json" } })
      .then(function (r) { if (!r.ok) throw new Error("failed"); return r.json(); })
      .then(function (payload) {
        var list = Array.isArray(payload && payload.data) ? payload.data : [];
        groupsCache = list.map(function (item) {
          var g = item.group || {};
          return { id: String(g.id || ""), name: g.name || "", servers: new Set((item.servers || []).map(String)) };
        }).filter(function (g) { return g.id; });
        groupsPromise = null;
        return groupsCache;
      })
      .catch(function () { groupsPromise = null; return groupsCache || []; });
    return groupsPromise;
  }

  function loadServers() {
    if (serversCache) return Promise.resolve(serversCache);
    if (serversPromise) return serversPromise;
    serversPromise = fetch("/api/v1/server", { credentials: "same-origin", headers: { Accept: "application/json" } })
      .then(function (r) { if (!r.ok) throw new Error("failed"); return r.json(); })
      .then(function (payload) { serversCache = Array.isArray(payload && payload.data) ? payload.data : []; serversPromise = null; return serversCache; })
      .catch(function () { serversPromise = null; return serversCache || []; });
    return serversPromise;
  }

  // ---- 对话框识别 ----
  // 判断是否是编辑服务器对话框：
  // 1. 有 h2/[role=heading] 文字匹配"编辑服务器"系列，且不含分组/配置关键词
  // 2. 或者有 form + name input + "对游客隐藏"文字（兜底）
  function isEditServerDialog(dialog) {
    // 已注入直接认领
    if (dialog.querySelector("[" + FIELD_ATTR + "]")) return true;
    var heading = dialog.querySelector("h2, [role='heading']");
    var headingText = (heading && heading.textContent) || "";
    if (/编辑服务器|Edit Server|EditServer/.test(headingText) && !/分组|配置|Config|Group/i.test(headingText)) return true;
    // 兜底：有服务器编辑表单特征
    return !!dialog.querySelector('form input[name="name"]') &&
      /对游客隐藏|Hidden from Visitors|HideForGuest/.test(dialog.textContent || "");
  }

  var lastClickedServerId = "";

  // 从点击的 DOM 节点向上找服务器 ID（表格行格式 "12(0) ..."）
  function detectClickServerId(event) {
    if (!isDashboard()) return;
    var node = event.target;
    for (var i = 0; node && i < 20; i++, node = node.parentElement) {
      var text = (node.textContent || "").trim();
      var m = text.match(/(?:^|\s)(\d+)\(\d+\)(?:\s|$)/);
      if (m) { lastClickedServerId = m[1]; return; }
    }
  }

  function resolveServerId(dialog) {
    var stored = dialog.getAttribute("data-custom-edit-server-id");
    if (stored) return Promise.resolve(stored);
    // 对话框文本里找 ID(display_index)
    var m = (dialog.textContent || "").match(/(?:^|\s)(\d+)\(\d+\)(?:\s|$)/);
    if (m) return Promise.resolve(m[1]);
    // 上次点击的服务器
    if (lastClickedServerId) return Promise.resolve(lastClickedServerId);
    // 靠 name 反查服务器列表（卡片视图或慢加载场景）
    var nameInput = dialog.querySelector('form input[name="name"]');
    var name = nameInput && String(nameInput.value || "").trim();
    if (!name) return Promise.resolve("");
    return loadServers().then(function (servers) {
      var s = servers.find(function (s) { return String(s.name || "").trim() === name; });
      return s ? String(s.id) : "";
    });
  }

  // ---- 注入分组字段 ----

  function buildGroupField() {
    var wrapper = document.createElement("div");
    wrapper.className = "grid gap-2";
    wrapper.setAttribute(FIELD_ATTR, "true");
    wrapper.innerHTML =
      '<label class="text-sm font-medium leading-none">服务器分组</label>' +
      '<div class="custom-edit-group-list grid grid-cols-2 gap-1 overflow-y-auto rounded-md border p-2">' +
      '<span class="text-xs text-muted-foreground col-span-2">加载中…</span></div>' +
      '<p class="text-xs text-muted-foreground custom-edit-group-status" aria-live="polite">保存服务器后自动同步分组关系。</p>';
    return wrapper;
  }

  function renderGroupCheckboxes(wrapper, serverId) {
    var listEl = wrapper.querySelector(".custom-edit-group-list");
    loadGroups(true).then(function (groups) {
      listEl.innerHTML = "";
      if (!groups.length) {
        listEl.innerHTML = '<span class="text-xs text-muted-foreground col-span-2">暂无分组（可在"分组"页面创建）</span>';
        return;
      }
      groups.forEach(function (group) {
        var label = document.createElement("label");
        label.className = "flex items-center gap-2 text-sm";
        var input = document.createElement("input");
        input.type = "checkbox";
        input.className = CHECK_CLASS + " h-4 w-4";
        input.value = group.id;
        input.checked = serverId ? group.servers.has(String(serverId)) : false;
        input.dataset.initial = input.checked ? "1" : "0";
        var span = document.createElement("span");
        span.textContent = group.name + " (#" + group.id + ")";
        label.appendChild(input);
        label.appendChild(span);
        listEl.appendChild(label);
      });
    });
  }

  function insertFieldIntoForm(form, field) {
    // 插到"对游客隐藏"字段之后
    var anchor = null;
    var labels = form.querySelectorAll("label");
    for (var i = 0; i < labels.length; i++) {
      if (/对游客隐藏|Hidden from Visitors|HideForGuest/.test((labels[i].textContent || "").trim())) {
        // 向上找最近的 FormItem 容器，但不能超出 form
        var node = labels[i].parentElement;
        while (node && node !== form) {
          // FormItem 通常是 form 的直接子 div 或次级容器
          if (node.parentElement === form || node.parentElement === form.firstElementChild) {
            anchor = node;
            break;
          }
          node = node.parentElement;
        }
        if (!anchor) anchor = labels[i].parentElement;
        break;
      }
    }
    if (anchor && anchor.parentElement && form.contains(anchor)) {
      anchor.parentElement.insertBefore(field, anchor.nextSibling);
      return;
    }
    // 兜底：插到提交按钮前面
    var submitBtn = form.querySelector('[type="submit"]');
    var actionsRow = submitBtn && submitBtn.closest("div");
    if (actionsRow && actionsRow.parentElement && form.contains(actionsRow)) {
      actionsRow.parentElement.insertBefore(field, actionsRow);
    } else {
      form.appendChild(field);
    }
  }

  // 核心注入函数，支持重试
  function tryInjectDialog(dialog, attempt) {
    if (!isDashboard()) return;
    if (dialog.querySelector("[" + FIELD_ATTR + "]")) return; // 已注入
    if (dialog.getAttribute("data-custom-injecting") === "true") return;

    var form = dialog.querySelector("form");
    if (!form) {
      // form 还没渲染，最多重试 10 次（每 200ms）
      if ((attempt || 0) < 10) {
        window.setTimeout(function () { tryInjectDialog(dialog, (attempt || 0) + 1); }, 200);
      }
      return;
    }

    dialog.setAttribute("data-custom-injecting", "true");

    var field = buildGroupField();
    insertFieldIntoForm(form, field);
    form.setAttribute(FORM_ATTR, "true");

    resolveServerId(dialog).then(function (serverId) {
      dialog.setAttribute("data-custom-edit-server-id", serverId || "");
      renderGroupCheckboxes(field, serverId);
    });
  }

  function scanDialogs() {
    if (!isDashboard()) return;
    document.querySelectorAll('[role="dialog"]').forEach(function (dialog) {
      if (!isEditServerDialog(dialog)) return;
      if (dialog.querySelector("[" + FIELD_ATTR + "]")) return;
      tryInjectDialog(dialog, 0);
    });
  }

  // ---- 保存后同步分组 ----

  function collectDesired(dialog) {
    var desired = { add: new Set(), remove: new Set() };
    dialog.querySelectorAll("." + CHECK_CLASS).forEach(function (input) {
      var initial = input.dataset.initial === "1";
      if (input.checked && !initial) desired.add.add(input.value);
      if (!input.checked && initial) desired.remove.add(input.value);
    });
    return desired;
  }

  function fetchGroupFresh(groupId) {
    return fetch("/api/v1/server-group", { credentials: "same-origin", headers: { Accept: "application/json" } })
      .then(function (r) { if (!r.ok) throw new Error("failed"); return r.json(); })
      .then(function (payload) {
        var list = Array.isArray(payload && payload.data) ? payload.data : [];
        var item = list.find(function (g) { return String((g.group || {}).id) === String(groupId); });
        if (!item) throw new Error("group not found");
        return { id: String(item.group.id), name: item.group.name || "", servers: new Set((item.servers || []).map(String)) };
      });
  }

  function syncGroup(groupId, op, serverId) {
    return fetchGroupFresh(groupId).then(function (group) {
      var members = new Set(group.servers);
      if (op === "add") members.add(String(serverId));
      else members.delete(String(serverId));
      return fetch("/api/v1/server-group/" + groupId, {
        method: "PATCH",
        credentials: "same-origin",
        headers: requestHeaders(),
        body: JSON.stringify({ name: group.name, servers: Array.from(members).map(Number) })
      }).then(function (r) {
        if (!r.ok) throw new Error("patch failed");
        if (groupsCache) {
          var c = groupsCache.find(function (g) { return g.id === String(groupId); });
          if (c) c.servers = members;
        }
      });
    });
  }

  function applyPending(serverId) {
    var pending = pendingByServer[String(serverId)];
    if (!pending) return Promise.resolve();
    delete pendingByServer[String(serverId)];
    var tasks = [];
    pending.add.forEach(function (gid) { tasks.push(syncGroup(gid, "add", serverId)); });
    pending.remove.forEach(function (gid) { tasks.push(syncGroup(gid, "remove", serverId)); });
    return Promise.all(tasks.map(function (t) {
      return t.then(function () { return true; }).catch(function (e) { console.error("[edit-group]", e); return false; });
    })).then(function (results) {
      var failed = results.filter(function (ok) { return !ok; }).length;
      var dialog = document.querySelector('[role="dialog"][data-custom-edit-server-id="' + serverId + '"]');
      var el = dialog && dialog.querySelector(".custom-edit-group-status");
      if (el) el.textContent = failed === 0 ? "分组已同步" : failed + " 个分组同步失败，请重试";
      // 分组同步成功后，等对话框关闭再刷新页面（zustand store 无法从外部直接更新）
      if (failed === 0) {
        // reload 前先拿最新分组数据写入 localStorage 缓存，reload 后 zustand hydrate 直接用新值
        fetch("/api/v1/server-group", { credentials: "same-origin", headers: { Accept: "application/json" } })
          .then(function (r) { return r.ok ? r.json() : null; })
          .then(function (payload) {
            if (payload && payload.data) {
              try {
                var raw = localStorage.getItem("serverStore");
                if (raw) {
                  var store = JSON.parse(raw);
                  if (store && store.state) {
                    store.state.serverGroup = payload.data;
                    localStorage.setItem("serverStore", JSON.stringify(store));
                  }
                }
              } catch (e) { /* ignore */ }
            }
            // 等对话框关闭后 reload
            var checkClose = function () {
              var dlg = document.querySelector('[role="dialog"][data-custom-edit-server-id="' + serverId + '"]');
              if (!dlg || dlg.offsetParent === null || !document.contains(dlg)) {
                window.location.reload();
              } else {
                window.setTimeout(checkClose, 300);
              }
            };
            window.setTimeout(checkClose, 300);
          })
          .catch(function () {});
      }
    });
  }

  function patchFetch() {
    if (fetchPatched) return;
    fetchPatched = true;
    var orig = window.fetch;
    window.fetch = function (input, init) {
      var url = typeof input === "string" ? input : (input && input.url) || "";
      var method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
      var m = url.match(/\/api\/v1\/server\/(\d+)(\?.*)?$/);
      if (method === "PATCH" && m) {
        var sid = m[1];
        var dialog = document.querySelector('[role="dialog"][data-custom-edit-server-id="' + sid + '"]')
          || document.querySelector('[role="dialog"][' + FIELD_ATTR + ']');
        if (dialog) dialog.setAttribute("data-custom-edit-server-id", sid);
        if (dialog && dialog.querySelector("[" + FIELD_ATTR + "]")) {
          var desired = collectDesired(dialog);
          if (desired.add.size || desired.remove.size) pendingByServer[sid] = desired;
          var el = dialog.querySelector(".custom-edit-group-status");
          if (el) el.textContent = "正在同步分组…";
        }
        return orig.apply(this, arguments).then(function (r) {
          if (r && r.ok && pendingByServer[sid]) return applyPending(sid).then(function () { return r; });
          return r;
        });
      }
      return orig.apply(this, arguments);
    };
  }

  // ---- 启动 ----

  var scanTimer = 0;
  function debouncedScan() {
    if (scanTimer) return;
    scanTimer = window.requestAnimationFrame(function () {
      scanTimer = 0;
      scanDialogs();
    });
  }

  document.addEventListener("click", function (e) {
    if (!isDashboard()) return;
    detectClickServerId(e);
    // 点击后延迟扫描，等 React Dialog 挂载
    window.setTimeout(debouncedScan, 150);
    window.setTimeout(debouncedScan, 400);
  }, true);

  // MutationObserver 兜底，通过 debounce 限频
  new MutationObserver(debouncedScan).observe(document.documentElement, { childList: true, subtree: true });

  patchFetch();
  debouncedScan();

  window.addEventListener("popstate", function () { window.setTimeout(scanDialogs, 0); });
})();
