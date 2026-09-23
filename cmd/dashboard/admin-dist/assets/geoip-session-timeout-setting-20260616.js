(function () {
  if (window.__geoipSessionTimeoutSettingInstalled) return;
  window.__geoipSessionTimeoutSettingInstalled = true;

  var currentTimeout = null;
  var MIN_TIMEOUT = 24;
  var MAX_TIMEOUT = 720;
  var inputId = "geoip-jwt-timeout-input";
  var fieldId = "geoip-jwt-timeout-field";

  function isSettingUrl(input) {
    try {
      var url = new URL(input, window.location.origin);
      return url.origin === window.location.origin && url.pathname === "/api/v1/setting";
    } catch (_e) {
      return false;
    }
  }

  function rememberTimeoutFromResponse(data) {
    var value = data && data.data && data.data.config && data.data.config.jwt_timeout;
    if (Number.isFinite(Number(value)) && Number(value) > 0) {
      currentTimeout = Math.max(MIN_TIMEOUT, Math.min(MAX_TIMEOUT, Math.round(Number(value))));
      var input = document.getElementById(inputId);
      if (input && document.activeElement !== input) input.value = String(currentTimeout);
    }
  }

  function readTimeoutInput() {
    var input = document.getElementById(inputId);
    if (!input) return currentTimeout;

    var value = Number(input.value);
    if (!Number.isFinite(value)) return currentTimeout;

    value = Math.round(value);
    if (value < MIN_TIMEOUT) value = MIN_TIMEOUT;
    if (value > MAX_TIMEOUT) value = MAX_TIMEOUT;
    input.value = String(value);
    currentTimeout = value;
    return value;
  }

  var nativeFetch = window.fetch;
  if (typeof nativeFetch === "function") {
    window.fetch = function (input, init) {
      var url = typeof input === "string" ? input : input && input.url;
      var method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();

      if (isSettingUrl(url) && method === "PATCH" && init && typeof init.body === "string") {
        try {
          var body = JSON.parse(init.body);
          var timeout = readTimeoutInput();
          if (Number.isFinite(timeout) && timeout > 0) {
            body.jwt_timeout = timeout;
            init = Object.assign({}, init, { body: JSON.stringify(body) });
          }
        } catch (_e) {}
      }

      return nativeFetch.call(this, input, init).then(function (response) {
        if (isSettingUrl(url) && method === "GET") {
          response
            .clone()
            .json()
            .then(rememberTimeoutFromResponse)
            .catch(function () {});
        }
        return response;
      });
    };
  }

  function makeField() {
    var wrapper = document.createElement("div");
    wrapper.id = fieldId;
    wrapper.className = "grid gap-2";
    wrapper.innerHTML =
      '<label class="text-sm font-medium leading-none" for="' +
      inputId +
      '">登录会话时长（小时）</label>' +
      '<input id="' +
      inputId +
      '" class="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm transition-colors outline-none focus-visible:ring-1 focus-visible:ring-ring" type="number" min="24" max="720" step="1" inputmode="numeric">' +
      '<p class="text-xs text-muted-foreground">范围 24-720 小时，保存后新登录和后续刷新生效。</p>';
    return wrapper;
  }

  function insertField() {
    if (document.getElementById(fieldId)) return;
    if (window.location.pathname !== "/dashboard/settings") return;

    var customDashboardLabel = Array.from(document.querySelectorAll("label")).find(function (label) {
      return /CustomCodesDashboard|仪表板的自定义代码|自定义代码/.test(label.textContent || "");
    });
    var anchor = customDashboardLabel && customDashboardLabel.closest(".grid");

    if (!anchor) {
      var form = document.querySelector("form");
      anchor = form && Array.from(form.querySelectorAll(".grid.gap-2")).pop();
    }
    if (!anchor || !anchor.parentElement) return;

    var field = makeField();
    anchor.parentElement.insertBefore(field, anchor.nextSibling);
    var input = document.getElementById(inputId);
    input.value = String(currentTimeout || MIN_TIMEOUT);
  }

  var observer = new MutationObserver(insertField);
  observer.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener("popstate", function () {
    window.setTimeout(insertField, 0);
  });
  for (var delay of [0, 300, 1000, 2500]) {
    window.setTimeout(insertField, delay);
  }
})();
