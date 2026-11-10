// The variable browser: the project's rooms, devices and variables, which the integrator searches and inserts
// PARAM{device,variable} tokens from. A page embeds it after page.js, with variables.css after style.css, and its
// driver answers with lib.ui.devices' serve().
//   Kit.devices                       what the driver lists, kept for every browser on the page:
//     load()                          asks for the list again; resolves with it
//     list()                          the entries, [] before the first answer
//     device(id)                      the entry with that id, or with a member of that id, or null
//     variables(id)                   an entry's variables, or null while they load (asking once)
//     whenVariables(id)               the same as a Promise, null when no answer comes in time
//     variable(ownerId, varId)        the variable a token names, by id or name, or null while it loads or is gone
//     onChange(fn)                    fn(id) after an entry's variables arrive, fn(null) after the list; returns a stop
//     demo(devices, variablesById)    answers the two commands in demo mode with this data
//   Kit.variableBrowser(el, options)  a search box, the tree and a footer in el; returns { render(), refresh() }
//     target    the field a pick goes into: an element, a selector, or a function given the last focused [data-tok]
//               field (or null) that returns one; the default is that field, else the first [data-tok] field
//     token(v)  a pick's text, by default PARAM{deviceId,id}
//     onPick(v) what a pick does, by default inserts the token at the target's caret and fires its input event
//     usedIn    the fields whose tokens tick a variable as used: elements, a selector or a function; default the
//               target. Typing in one redraws the ticks; a page that sets a value itself calls render().
// A pick, v, is the variable's row with deviceId the member owning it and device its entry.

(function (Kit) {
  var AUTO_OPEN = 25; // a search opens the devices it finds up to this many; past it they wait for a narrower one
  var ASKS = 15; // variable lists a render waits on at once, so a search never asks for every device in the project
  var TOKEN = /PARAM\s*\{\s*([^,}]*?)\s*,\s*([^}]*?)\s*\}/g;

  // Ids go into markup, tokens and the store's keys as digits only.
  function digits(id) {
    return Kit.str(id).replace(/[^0-9]/g, "");
  }
  var key = digits;

  // ─── The store ───────────────────────────────────────────────────────────

  var entries = [];
  var listed = false;
  var cache = {}; // entry id -> its variables
  var asked = {}; // entry id -> true while its variables are on the way
  var known = {}; // entry id -> true once read: a search asks for it again after the list reloads
  var waiting = {}; // entry id -> the whenVariables waiting on it
  var watchers = [];

  function notify(id) {
    watchers.slice().forEach(function (fn) {
      try {
        fn(id);
      } catch (e) {
        console.error("Variable browser:", e);
      }
    });
  }

  function settle(k, rows) {
    var list = waiting[k];
    delete waiting[k];
    (list || []).forEach(function (fn) {
      fn(rows);
    });
  }

  function ask(id) {
    var k = key(id);
    if (!k || asked[k] || cache[k]) return;
    asked[k] = true;
    Kit.sendCommand("_GET_DEVICE_VARIABLES", { deviceId: Number(k) });
  }

  Kit.listen("DEVICES_DATA", function (data) {
    entries = Array.isArray(data.devices) ? data.devices : [];
    listed = true;
    // Values move, so a new list reads them again.
    cache = {};
    asked = {};
    notify(null);
  });

  Kit.listen("DEVICE_VARIABLES_DATA", function (data) {
    var k = key(data.deviceId);
    if (!k) return;
    var rows = Array.isArray(data.variables) ? data.variables : [];
    cache[k] = rows;
    known[k] = true;
    delete asked[k];
    settle(k, rows);
    notify(k);
  });

  // A refusal answers what waits; the asks stay marked, so a render does not ask again in a loop.
  Kit.listen("ERROR", function () {
    Object.keys(waiting).forEach(function (k) {
      settle(k, null);
    });
  });

  function load() {
    return Kit.call("_GET_DEVICES", {}, "DEVICES_DATA").then(function () {
      return entries;
    });
  }

  function device(id) {
    var k = key(id);
    for (var i = 0; i < entries.length; i++) {
      var d = entries[i];
      if (key(d.id) === k) return d;
      var members = d.memberIds || [];
      for (var j = 0; j < members.length; j++) {
        if (key(members[j]) === k) return d;
      }
    }
    return null;
  }

  function variables(id) {
    var k = key(id);
    if (cache[k]) return cache[k];
    ask(k);
    return null;
  }

  function whenVariables(id, ms) {
    var k = key(id);
    if (cache[k]) return Promise.resolve(cache[k]);
    return new Promise(function (resolve) {
      var timer = setTimeout(function () {
        var list = waiting[k] || [];
        var i = list.indexOf(finish);
        if (i >= 0) list.splice(i, 1);
        if (!list.length) delete waiting[k];
        // Lost on the way: a later look may ask again.
        delete asked[k];
        resolve(null);
      }, ms || 10000);
      function finish(rows) {
        clearTimeout(timer);
        resolve(rows);
      }
      (waiting[k] = waiting[k] || []).push(finish);
      ask(k);
    });
  }

  function ownerOf(row, entryId) {
    return row.deviceId !== undefined && row.deviceId !== null ? row.deviceId : entryId;
  }

  function variable(ownerId, varId) {
    var entry = device(ownerId);
    var rows = entry ? variables(entry.id) : null;
    if (!rows) return null;
    var o = key(ownerId);
    var v = Kit.str(varId);
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      if (key(ownerOf(row, entry.id)) === o && (Kit.str(row.id) === v || Kit.str(row.name) === v)) return row;
    }
    return null;
  }

  function onChange(fn) {
    watchers.push(fn);
    return function () {
      var i = watchers.indexOf(fn);
      if (i >= 0) watchers.splice(i, 1);
    };
  }

  function demo(devices, variablesById) {
    Kit.demoAnswer("_GET_DEVICES", function () {
      Kit.deliver("DEVICES_DATA", { devices: devices || [] });
    });
    Kit.demoAnswer("_GET_DEVICE_VARIABLES", function (command, params) {
      var k = key(params && params.deviceId);
      Kit.deliver("DEVICE_VARIABLES_DATA", { deviceId: k, variables: (variablesById || {})[k] || [] });
    });
  }

  Kit.devices = {
    load: load,
    list: function () {
      return entries;
    },
    device: device,
    variables: variables,
    whenVariables: whenVariables,
    variable: variable,
    onChange: onChange,
    demo: demo,
  };

  // ─── The browser ─────────────────────────────────────────────────────────

  var lastTok = null;
  var tracking = false;

  // The last focused [data-tok] field, the default target.
  function trackTokenFields() {
    if (tracking) return;
    tracking = true;
    document.addEventListener("focusin", function (e) {
      var t = e.target;
      if (t && t.getAttribute && t.getAttribute("data-tok") !== null) lastTok = t;
    });
  }

  function fieldsOf(spec) {
    if (typeof spec === "function") spec = spec();
    if (typeof spec === "string") spec = document.querySelectorAll(spec);
    if (!spec) return [];
    if (spec.nodeType === 1) return [spec];
    return Array.prototype.slice.call(spec);
  }

  function insertAtCaret(field, text) {
    var value = Kit.str(field.value);
    var start = null;
    var end = null;
    // A field type without a selection throws on reading one in some engines.
    try {
      start = field.selectionStart;
      end = field.selectionEnd;
    } catch (e) {}
    if (typeof start !== "number") start = end = value.length;
    if (typeof end !== "number") end = start;
    field.value = value.slice(0, start) + text + value.slice(end);
    var caret = start + text.length;
    if (field.focus) field.focus();
    try {
      field.setSelectionRange(caret, caret);
    } catch (e) {}
    field.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function variableBrowser(el, options) {
    options = options || {};
    trackTokenFields();

    var search = document.createElement("input");
    search.type = "search";
    search.className = "kit-vb-search";
    search.placeholder = "Search rooms, devices, variables";
    search.setAttribute("aria-label", "Search rooms, devices, variables");
    var tree = document.createElement("div");
    tree.className = "kit-vb-tree";
    var foot = document.createElement("div");
    foot.className = "kit-vb-foot";
    el.classList.add("kit-vb");
    el.innerHTML = "";
    el.appendChild(search);
    el.appendChild(tree);
    el.appendChild(foot);

    var opened = {}; // entry id -> true: opened by a click outside a search
    var flipped = {}; // entry id -> true: a click during this search turned it from how the search shows it
    var query = "";

    function target() {
      var t = options.target;
      var last = lastTok && document.contains(lastTok) ? lastTok : null;
      if (typeof t === "function") return t(last) || null;
      if (typeof t === "string") return document.querySelector(t);
      return t || last || document.querySelector("[data-tok]");
    }

    function usedFields() {
      return options.usedIn !== undefined && options.usedIn !== null ? fieldsOf(options.usedIn) : fieldsOf(target());
    }

    function usedSet() {
      var set = {};
      usedFields().forEach(function (field) {
        var text = Kit.str(field.value);
        var m;
        TOKEN.lastIndex = 0;
        while ((m = TOKEN.exec(text)) !== null) set[m[1] + ":" + m[2]] = true;
      });
      return set;
    }

    function has(text) {
      return Kit.str(text).toLowerCase().indexOf(query) !== -1;
    }

    // Escapes the text and marks where the search matches it; split before escaping, so a match never cuts an entity.
    function mark(text) {
      text = Kit.str(text);
      if (!query) return Kit.esc(text);
      var lower = text.toLowerCase();
      var out = "";
      var at = 0;
      var i;
      while ((i = lower.indexOf(query, at)) !== -1) {
        out += Kit.esc(text.slice(at, i));
        out += '<mark class="kit-vb-hl">' + Kit.esc(text.slice(i, i + query.length)) + "</mark>";
        at = i + query.length;
      }
      return out + Kit.esc(text.slice(at));
    }

    function note(text) {
      return '<div class="kit-vb-note">' + Kit.esc(text) + "</div>";
    }

    function render() {
      var q = Kit.str(search.value).trim().toLowerCase();
      if (q !== query) {
        flipped = {};
        query = q;
      }
      var used = usedSet();
      var waits = 0;

      // Waits on an entry's variables, within the render's share of asks.
      function want(id) {
        if (cache[key(id)]) return;
        if (waits >= ASKS) return;
        waits++;
        ask(id);
      }

      var visible = [];
      entries.forEach(function (d) {
        var k = key(d.id);
        var room = d.roomName || "No Room";
        var vars = cache[k];
        var matching = null;
        if (q && !has(d.name) && !has(room)) {
          // A variable's name is searched where its list is here; one read before a reload is asked for again.
          if (!vars) {
            if (known[k]) want(d.id);
            return;
          }
          matching = vars.filter(function (v) {
            return has(v.name);
          });
          if (!matching.length) return;
        }
        visible.push({ d: d, room: room, matching: matching });
      });

      var autoOpen = q && visible.length <= AUTO_OPEN;
      var html = "";
      var group = null;
      visible.forEach(function (item) {
        var d = item.d;
        var k = key(d.id);
        // A section and room together, so the agents never join a room of the same name.
        var g = Kit.str(d.section) + "\n" + item.room;
        if (g !== group) {
          html += '<div class="kit-vb-room">' + mark(item.room) + "</div>";
          group = g;
        }
        var open = q ? !!(autoOpen || item.matching) !== !!flipped[k] : !!opened[k];
        if (open) want(d.id);
        var vars = cache[k];
        html +=
          '<button type="button" class="kit-vb-dev" data-device="' + digits(d.id) + '" aria-expanded="' + open + '">' +
          '<span class="kit-vb-chev">' + (open ? "&#9662;" : "&#9656;") + "</span>" +
          '<span class="kit-vb-dname">' + mark(d.name) + "</span></button>";
        if (!open) return;
        if (!vars) {
          html += note("Loading variables…");
          return;
        }
        var rows = item.matching || vars;
        if (!rows.length) html += note("No variables");
        var section = null;
        rows.forEach(function (v) {
          // An entry spans a driver and the proxies restating it: each member's block has a heading, and a token
          // names the member owning the variable.
          if (v.section && v.section !== section) {
            html += '<div class="kit-vb-section">' + Kit.esc(v.section) + "</div>";
            section = v.section;
          }
          var owner = digits(ownerOf(v, d.id));
          var isUsed = used[owner + ":" + Kit.str(v.id)] || used[owner + ":" + Kit.str(v.name)];
          html +=
            '<button type="button" class="kit-vb-var' + (isUsed ? " kit-vb-used" : "") + '"' +
            ' data-entry="' + digits(d.id) + '" data-owner="' + owner + '" data-var="' + digits(v.id) + '"' +
            ' title="' + Kit.esc(d.name) + " &gt; " + Kit.esc(v.name) + '">' +
            '<span class="kit-vb-name">' + mark(v.name) + "</span>" +
            '<span class="kit-vb-value">' + Kit.esc(v.value) + "</span>" +
            '<span class="kit-vb-ins">Insert</span></button>';
        });
      });

      tree.innerHTML = html || note(entries.length ? "No matches" : listed ? "No devices" : "Loading devices…");
      foot.textContent = entries.length ? visible.length + " of " + entries.length + " devices" : "";
    }

    function toggle(id) {
      var k = key(id);
      if (query) {
        if (flipped[k]) delete flipped[k];
        else flipped[k] = true;
      } else if (opened[k]) {
        delete opened[k];
      } else {
        opened[k] = true;
      }
      render();
    }

    function token(v) {
      return "PARAM{" + digits(v.deviceId) + "," + digits(v.id) + "}";
    }

    function insert(v) {
      var field = target();
      if (field) insertAtCaret(field, (options.token || token)(v));
    }

    function pick(entryId, ownerId, varId) {
      var rows = cache[entryId] || [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (digits(ownerOf(row, entryId)) === ownerId && digits(row.id) === varId) {
          var v = {};
          Object.keys(row).forEach(function (name) {
            v[name] = row[name];
          });
          v.deviceId = ownerOf(row, Number(entryId));
          v.device = device(entryId);
          (options.onPick || insert)(v);
          render();
          return;
        }
      }
    }

    // One delegated click: a row is a button carrying its ids.
    tree.addEventListener("click", function (e) {
      var node = e.target;
      while (node && node !== tree) {
        if (node.getAttribute && node.getAttribute("data-var") !== null) {
          pick(node.getAttribute("data-entry"), node.getAttribute("data-owner"), node.getAttribute("data-var"));
          return;
        }
        if (node.getAttribute && node.getAttribute("data-device") !== null) {
          toggle(node.getAttribute("data-device"));
          return;
        }
        node = node.parentNode;
      }
    });

    search.addEventListener("input", render);

    // Typing in a field the ticks read redraws them.
    document.addEventListener("input", function (e) {
      if (e.target !== search && usedFields().indexOf(e.target) !== -1) render();
    });

    onChange(render);
    render();

    return {
      render: render,
      // Asks for the list again, as a page does on each connect and each time it shows the browser.
      refresh: function () {
        render();
        return load();
      },
    };
  }

  Kit.variableBrowser = variableBrowser;
})(Kit);
