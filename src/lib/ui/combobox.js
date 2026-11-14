// A searchable dropdown, drawn as a compact select: a page that renders its HTML as a string puts the markup in,
// and drawing it again on the next render keeps it open, its search and its highlighted choice, by key. A page embeds
// it after page.js, with combobox.css after style.css.
//   Kit.combobox(key, options)  the control's markup. options:
//     label                     the trigger's text; empty shows the placeholder
//     placeholder               the trigger's text with nothing picked
//     title                     the trigger's tooltip, by default its label
//     items()                   the choices, [{ value, label, section }], or null while they load; a section heads the
//                               choices after it
//     value                     the picked choice's value, marked in the list
//     search                    false for a list with no search box
//     empty, loading            what an empty list and a loading one say
//     onPick(value, item)       a choice was made; the list closes
//     className, style          on the control, as a width
//   Kit.combobox.set(key, { label, value })  shows another pick on a drawn control without drawing the page again
//   Kit.combobox.refresh(key)   fills an open list again, as when its choices arrive
//   Kit.combobox.close()        closes the open list
// Escape closes the list, Up and Down move through it, Enter picks; a click outside it closes it.

(function (Kit) {
  var defs = {}; // key -> its latest options
  var openKey = null;
  var query = "";
  var active = -1;

  function control(key) {
    var all = document.querySelectorAll("[data-kit-combo]");
    for (var i = 0; i < all.length; i++) if (all[i].getAttribute("data-kit-combo") === key) return all[i];
    return null;
  }

  // The choices the search leaves, each with the section it is under.
  function shown(key) {
    var list = defs[key].items();
    if (!list) return null;
    var q = query.toLowerCase();
    return list.filter(function (it) {
      return !q || Kit.str(it.label).toLowerCase().indexOf(q) >= 0;
    });
  }

  function listHtml(key) {
    var def = defs[key];
    var list = shown(key);
    if (!list) return '<div class="kit-combo-none">' + Kit.esc(def.loading || "Loading…") + "</div>";
    if (!list.length) return '<div class="kit-combo-none">' + Kit.esc(def.empty || "No matches") + "</div>";
    var section = null;
    return list
      .map(function (it, i) {
        var head = "";
        if (it.section && it.section !== section) {
          head = '<div class="kit-combo-section">' + Kit.esc(it.section) + "</div>";
          section = it.section;
        }
        var cls = "kit-combo-item" + (Kit.str(it.value) === Kit.str(def.value) ? " selected" : "") + (i === active ? " active" : "");
        return head + '<div class="' + cls + '" role="option" data-index="' + i + '">' + Kit.esc(it.label) + "</div>";
      })
      .join("");
  }

  function combobox(key, options) {
    defs[key] = options;
    var isOpen = key === openKey;
    var label = Kit.str(options.label);
    var html =
      '<div class="kit-combo' + (isOpen ? " open" : "") + (options.className ? " " + options.className : "") + '" data-kit-combo="' + Kit.esc(key) + '"' +
      (options.style ? ' style="' + Kit.esc(options.style) + '"' : "") + ">" +
      '<button type="button" class="kit-combo-trigger' + (label ? "" : " placeholder") + '" aria-haspopup="listbox" aria-expanded="' + isOpen + '"' +
      ' title="' + Kit.esc(options.title || label) + '">' + Kit.esc(label || options.placeholder || "") + "</button>" +
      '<div class="kit-combo-pop">' +
      (options.search === false ? "" : '<input type="text" class="kit-combo-search" placeholder="Search…" value="' + Kit.esc(isOpen ? query : "") + '">') +
      '<div class="kit-combo-list" role="listbox">' + (isOpen ? listHtml(key) : "") + "</div></div></div>";
    // Drawn again while open, the search keeps the focus it had once the page has put this in.
    if (isOpen) setTimeout(focusOpen, 0);
    return html;
  }

  function part(el, name) {
    return el.querySelector(".kit-combo-" + name);
  }

  function focusOpen() {
    var el = openKey === null ? null : control(openKey);
    if (!el) return;
    var search = part(el, "search");
    if (search && document.activeElement !== search) search.focus();
  }

  // A list that would leave the pane opens to the left or upward instead.
  function place(el) {
    var pop = part(el, "pop");
    pop.classList.remove("flip-right", "flip-up");
    var r = pop.getBoundingClientRect();
    var t = part(el, "trigger").getBoundingClientRect();
    var room = document.documentElement;
    if (r.right > room.clientWidth - 8) pop.classList.add("flip-right");
    var below = room.clientHeight - t.bottom;
    if (r.height > below - 8 && t.top > below) pop.classList.add("flip-up");
  }

  function fill(key) {
    var el = control(key);
    if (!el) return;
    part(el, "list").innerHTML = listHtml(key);
    var on = part(el, "list").querySelector(".active");
    if (on) on.scrollIntoView({ block: "nearest" });
    place(el);
  }

  function close() {
    var el = openKey === null ? null : control(openKey);
    openKey = null;
    if (!el) return;
    el.classList.remove("open");
    part(el, "trigger").setAttribute("aria-expanded", "false");
  }

  function open(key) {
    close();
    var el = control(key);
    if (!el) return;
    openKey = key;
    query = "";
    active = -1;
    el.classList.add("open");
    part(el, "trigger").setAttribute("aria-expanded", "true");
    var search = part(el, "search");
    if (search) search.value = "";
    fill(key);
    (search || part(el, "trigger")).focus();
  }

  function pick(key, index) {
    var list = shown(key);
    var it = list && list[index];
    if (!it) return;
    close();
    defs[key].onPick(it.value, it);
  }

  combobox.set = function (key, changes) {
    var def = defs[key];
    var el = control(key);
    if (!def) return;
    if ("label" in changes) def.label = changes.label;
    if ("value" in changes) def.value = changes.value;
    if (!el) return;
    var trigger = part(el, "trigger");
    var label = Kit.str(def.label);
    trigger.textContent = label || def.placeholder || "";
    trigger.title = def.title || label;
    trigger.classList.toggle("placeholder", !label);
    if (key === openKey) fill(key);
  };
  combobox.refresh = function (key) {
    if (key === openKey) fill(key);
  };
  combobox.close = close;

  document.addEventListener("click", function (e) {
    var el = e.target.closest ? e.target.closest("[data-kit-combo]") : null;
    var key = el ? el.getAttribute("data-kit-combo") : null;
    if (key === null || !defs[key]) return close();
    if (e.target.closest(".kit-combo-trigger")) return key === openKey ? close() : open(key);
    var item = e.target.closest(".kit-combo-item");
    if (item) pick(key, Number(item.getAttribute("data-index")));
  });
  document.addEventListener("input", function (e) {
    if (openKey === null || !e.target.classList || !e.target.classList.contains("kit-combo-search")) return;
    query = e.target.value;
    active = -1;
    fill(openKey);
  });
  document.addEventListener("keydown", function (e) {
    if (openKey === null || !e.target.closest || !e.target.closest("[data-kit-combo]")) return;
    var key = openKey;
    var count = (shown(key) || []).length;
    if (e.key === "Escape") {
      var el = control(key);
      close();
      if (el) part(el, "trigger").focus();
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      if (!count) return;
      active = e.key === "ArrowDown" ? (active + 1) % count : (active <= 0 ? count : active) - 1;
      fill(key);
    } else if (e.key === "Enter") {
      pick(key, active >= 0 ? active : count === 1 ? 0 : -1);
    } else {
      return;
    }
    e.preventDefault();
  });

  Kit.combobox = combobox;
})(Kit);
