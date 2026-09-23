(function () {
  var ATTR = "data-geoip-server-group-dialog";
  var FORM_ATTR = "data-geoip-server-group-form";
  var SERVER_FIELD_ATTR = "data-geoip-server-group-field";
  var SELECTOR_ATTR = "data-geoip-server-group-selector";
  var ACTIONS_ATTR = "data-geoip-server-group-actions";
  var BODY_CLASS = "geoip-server-group-dialog-open";
  var PAGE_CLASS = "geoip-server-group-page";
  var TITLE_MARKERS = [
    "编辑服务器分组",
    "创建服务器分组",
    "EditServerGroup",
    "CreateServerGroup",
    "Edit Server Group",
    "Create Server Group"
  ];

  function hasServerGroupTitle(dialog) {
    var text = dialog.textContent || "";
    if (window.location.pathname.indexOf("/dashboard/server-group") !== -1) {
      return true;
    }
    return TITLE_MARKERS.some(function (marker) {
      return text.indexOf(marker) !== -1;
    });
  }

  function findServerField(form) {
    var labels = form.querySelectorAll("label");
    for (var i = 0; i < labels.length; i += 1) {
      var text = (labels[i].textContent || "").trim();
      if (text === "服务器" || text === "服务器(ID)" || text === "Server") {
        return labels[i].closest("div");
      }
    }
    return null;
  }

  function findSelector(form, serverField) {
    if (serverField) {
      var fieldButton = serverField.querySelector("button");
      if (fieldButton) {
        return fieldButton;
      }
    }
    return form.querySelector("button:not([type])");
  }

  function findActions(form) {
    var children = Array.prototype.slice.call(form.children);
    for (var i = children.length - 1; i >= 0; i -= 1) {
      var text = children[i].textContent || "";
      if (
        (text.indexOf("确认") !== -1 || text.indexOf("Confirm") !== -1) &&
        (text.indexOf("关闭") !== -1 || text.indexOf("Close") !== -1)
      ) {
        return children[i];
      }
    }
    return children[children.length - 1] || null;
  }

  function clearMarks(dialog) {
    var nodes = dialog.querySelectorAll(
      "[" + FORM_ATTR + "],[" + SERVER_FIELD_ATTR + "],[" + SELECTOR_ATTR + "],[" + ACTIONS_ATTR + "]"
    );
    nodes.forEach(function (node) {
      node.removeAttribute(FORM_ATTR);
      node.removeAttribute(SERVER_FIELD_ATTR);
      node.removeAttribute(SELECTOR_ATTR);
      node.removeAttribute(ACTIONS_ATTR);
    });
  }

  function markDialogs() {
    var active = false;
    var dialogs = document.querySelectorAll('#root [role="dialog"]');

    document.body.classList.toggle(
      PAGE_CLASS,
      window.location.pathname.indexOf("/dashboard/server-group") !== -1
    );

    dialogs.forEach(function (dialog) {
      var form = dialog.querySelector("form");
      var serverField = form ? findServerField(form) : null;
      var actions = form ? findActions(form) : null;
      var selector = form ? findSelector(form, serverField) : null;
      var matched = !!form && !!selector && !!actions && hasServerGroupTitle(dialog);

      clearMarks(dialog);

      if (matched) {
        if (!serverField) {
          serverField = selector.closest("div");
        }
        active = true;
        dialog.setAttribute(ATTR, "true");
        form.setAttribute(FORM_ATTR, "true");
        if (serverField) {
          serverField.setAttribute(SERVER_FIELD_ATTR, "servers");
        }
        selector.setAttribute(SELECTOR_ATTR, "true");
        actions.setAttribute(ACTIONS_ATTR, "true");
      } else {
        dialog.removeAttribute(ATTR);
      }
    });

    document.body.classList.toggle(BODY_CLASS, active);
  }

  function scheduleMarkDialogs() {
    window.requestAnimationFrame(markDialogs);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", markDialogs, { once: true });
  } else {
    markDialogs();
  }

  document.addEventListener("click", scheduleMarkDialogs, true);
  document.addEventListener("keyup", scheduleMarkDialogs, true);
  new MutationObserver(scheduleMarkDialogs).observe(document.documentElement, {
    childList: true,
    subtree: true
  });
})();
