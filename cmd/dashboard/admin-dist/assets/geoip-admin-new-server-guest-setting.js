(function () {
  "use strict";

  if (window.__geoipNewServerGuestSettingInstalled) return;
  window.__geoipNewServerGuestSettingInstalled = true;

  var fieldId = "geoip-hide-new-servers-field";
  var inputId = "geoip-hide-new-servers-input";
  var statusId = "geoip-hide-new-servers-status";
  var settingConfig = null;

  function isSettingsPage() {
    return window.location.pathname === "/dashboard/settings";
  }

  function cookieValue(name) {
    var prefix = name + "=";
    var cookies = document.cookie ? document.cookie.split("; ") : [];
    for (var i = 0; i < cookies.length; i += 1) {
      if (cookies[i].indexOf(prefix) === 0) return decodeURIComponent(cookies[i].slice(prefix.length));
    }
    return "";
  }

  function requestHeaders() {
    var headers = { "Content-Type": "application/json" };
    var csrf = cookieValue("nz-csrf");
    if (csrf) headers["X-CSRF-Token"] = csrf;
    return headers;
  }

  function settingPayload(config, value) {
    return {
      dns_servers: config.dns_servers || "",
      ignored_ip_notification: config.ignored_ip_notification || "",
      ip_change_notification_group_id: config.ip_change_notification_group_id || 0,
      cover: config.cover || 0,
      site_name: config.site_name || "Nezha Monitoring",
      language: config.language || "zh-CN",
      install_host: config.install_host || "",
      dashboard_host: config.dashboard_host || "",
      reserved_hosts: config.reserved_hosts || "",
      waf_ip_whitelist: config.waf_ip_whitelist || "",
      custom_code: config.custom_code || "",
      custom_code_dashboard: config.custom_code_dashboard || "",
      web_real_ip_header: config.web_real_ip_header || "",
      agent_real_ip_header: config.agent_real_ip_header || "",
      user_template: config.user_template || "user-dist",
      jwt_timeout: config.jwt_timeout || 24,
      tls: !!config.tls,
      enable_ip_change_notification: !!config.enable_ip_change_notification,
      enable_plain_ip_in_notification: !!config.enable_plain_ip_in_notification,
      enable_mcp: !!config.enable_mcp,
      hide_new_servers_for_guest: value
    };
  }

  function setStatus(message, error) {
    var status = document.getElementById(statusId);
    if (!status) return;
    status.textContent = message;
    status.classList.toggle("text-destructive", !!error);
    status.classList.toggle("text-muted-foreground", !error);
  }

  async function loadSetting(input) {
    try {
      var response = await fetch("/api/v1/setting", { credentials: "same-origin" });
      var result = await response.json();
      if (!response.ok || !result.success || !result.data || !result.data.config) return;
      settingConfig = result.data.config;
      input.checked = settingConfig.hide_new_servers_for_guest !== false;
    } catch (_e) {}
  }

  async function saveSetting(input) {
    if (!settingConfig || input.disabled) return;
    input.disabled = true;
    setStatus("正在保存…", false);
    try {
      var response = await fetch("/api/v1/setting", {
        method: "PATCH",
        credentials: "same-origin",
        headers: requestHeaders(),
        body: JSON.stringify(settingPayload(settingConfig, input.checked))
      });
      if (!response.ok) throw new Error("setting update failed");
      settingConfig.hide_new_servers_for_guest = input.checked;
      setStatus("已保存", false);
    } catch (_e) {
      input.checked = !input.checked;
      setStatus("保存失败，请重试", true);
    } finally {
      input.disabled = false;
    }
  }

  function makeField() {
    var wrapper = document.createElement("div");
    wrapper.id = fieldId;
    wrapper.className = "grid gap-2";
    wrapper.innerHTML =
      '<div class="flex items-center gap-2">' +
      '<input id="' + inputId + '" class="h-4 w-4" type="checkbox">' +
      '<label class="text-sm font-medium leading-none" for="' + inputId + '">新服务器默认对游客隐藏</label>' +
      '</div>' +
      '<p class="text-xs text-muted-foreground">开启后，新 Agent 首次上线会自动隐藏；关闭后新服务器默认公开。</p>' +
      '<p id="' + statusId + '" class="text-xs text-muted-foreground" aria-live="polite"></p>';
    var input = wrapper.querySelector("#" + inputId);
    input.addEventListener("change", function () {
      saveSetting(input);
    });
    return wrapper;
  }

  function insertField() {
    if (!isSettingsPage() || document.getElementById(fieldId)) return;
    var anchor = document.getElementById("geoip-jwt-timeout-field");
    if (!anchor) {
      var labels = Array.from(document.querySelectorAll("label"));
      var customLabel = labels.find(function (label) {
        return /CustomCodesDashboard|仪表板的自定义代码|自定义代码/.test(label.textContent || "");
      });
      anchor = customLabel && customLabel.closest(".grid");
    }
    if (!anchor || !anchor.parentElement) return;
    var field = makeField();
    anchor.parentElement.insertBefore(field, anchor.nextSibling);
    loadSetting(field.querySelector("#" + inputId));
  }

  var observer = new MutationObserver(insertField);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("popstate", function () {
    window.setTimeout(insertField, 0);
  });
  [0, 300, 1000, 2500].forEach(function (delay) {
    window.setTimeout(insertField, delay);
  });
})();
