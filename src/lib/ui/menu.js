// A button with an arrow beside it that opens a menu of the other choices, for a page that draws its markup as
// strings and draws it again on every push: the open menu is kept by name, and a pick, a click elsewhere or Escape
// closes it. A page embeds it after page.js, and menu.css after style.css, the same way.
//   Kit.splitButton(name, button, items, options)  `button` (the main button's markup), its arrow and, while open, the
//       menu of `items`, each [label, pick]; `button` alone when there are no items. options.label names the arrow
//       for a screen reader, options.onChange() draws the page again after the menu opens or closes
//   Kit.menu.isOpen(name), Kit.menu.close()

(function (Kit) {
  var menus = {};
  var openName = null;

  function changed(name) {
    var m = menus[name];
    if (m && m.onChange) m.onChange();
  }

  function close() {
    var was = openName;
    openName = null;
    if (was !== null) changed(was);
  }

  function splitButton(name, button, items, options) {
    if (!button || !items || !items.length) return button;
    options = options || {};
    menus[name] = { items: items, onChange: options.onChange };
    var open = openName === name;
    // The arrow takes the main button's own look.
    var look = button.indexOf("btn-primary") >= 0 ? "btn-primary" : "btn-secondary";
    var n = Kit.esc(name);
    return (
      '<span class="kit-splitbtn">' + button +
      '<button type="button" class="btn ' + look + ' kit-splitbtn-arrow" data-kit-menu="' + n + '" aria-label="' +
      Kit.esc(options.label || "More") + '" aria-haspopup="menu" aria-expanded="' + open + '"></button>' +
      (open
        ? '<span class="kit-menu" role="menu">' +
          items
            .map(function (item, i) {
              return '<button type="button" role="menuitem" data-kit-menu-item="' + n + '" data-index="' + i + '">' +
                Kit.esc(item[0]) + "</button>";
            })
            .join("") +
          "</span>"
        : "") +
      "</span>"
    );
  }

  document.addEventListener("click", function (e) {
    var t = e.target && e.target.closest ? e.target : null;
    var arrow = t && t.closest("[data-kit-menu]");
    var item = !arrow && t && t.closest("[data-kit-menu-item]");
    if (arrow) {
      var name = arrow.getAttribute("data-kit-menu");
      openName = openName === name ? null : name;
      changed(name);
    } else if (item) {
      var m = menus[item.getAttribute("data-kit-menu-item")];
      var pick = m && m.items[Number(item.getAttribute("data-index"))];
      var was = openName;
      openName = null;
      if (pick) pick[1]();
      changed(was);
    } else {
      close();
    }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") close();
  });

  Kit.splitButton = splitButton;
  Kit.menu = {
    isOpen: function (name) {
      return openName === name;
    },
    close: close,
  };
})(Kit);
