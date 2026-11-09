// The kit for a driver's custom Composer tab: its link to the driver, the tab bar, the properties card and
// demo mode. A page embeds it first in its <script>, after style.css in its <style>, with the line
// "<!-- #embed ../../../../src/lib/ui/page.js -->", and then calls:
//   connectDriver(options)      pushes from the driver, by command; property changes made in Composer
//   sendCommand(command, params)  a command to the driver's UIR handlers
//   initTabs(onSwitch)          the tab bar, shown from two tabs
//   initPropertiesCard(el)      the properties card, for a driver using lib.ui.tab-properties
//   demoMode(answer)            outside Composer: the banner, and commands answered by the page's demo data
//   deliver(command, params)    hands a demo answer to the page as a push would arrive
//   esc(text)                   text made safe for HTML

var gApiHost, gDriverId, gApiToken;

(function () {
  var p = {};
  window.location.search.replace(/[?&]+([^=&]+)=([^&]*)/gi, function (m, k, v) {
    p[k] = decodeURIComponent(v);
  });
  gApiHost = p.apihost;
  gDriverId = p.driverid;
  gApiToken = p.apitoken;
})();

function str(value) {
  return value === undefined || value === null ? "" : String(value);
}

function esc(text) {
  return str(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function parseJson(text, fallback) {
  try {
    return JSON.parse(text);
  } catch (e) {
    return fallback;
  }
}

// An apihost that carries its own http:// or https:// is used as given, so the page also runs through a dev proxy.
function apiOrigin() {
  return /^https?:\/\//i.test(gApiHost) ? gApiHost.replace(/\/$/, "") : "https://" + gApiHost;
}

function api(method, path, body) {
  if (!gApiHost) return Promise.resolve(null);
  var opts = { method: method, headers: { Authorization: "Bearer " + gApiToken, "Content-Type": "application/json" } };
  if (body) opts.body = JSON.stringify(body);
  return fetch(apiOrigin() + path, opts)
    .then(function (r) {
      return r.json();
    })
    .catch(function (e) {
      console.error("API error:", method, path, e);
      return null;
    });
}

// UTF-8, since btoa takes only Latin-1, broken by a newline every 76 characters: the broker's cost grows with the
// square of an unbroken run. lib.ui.page-params strips them before decoding.
function encodeParams(params) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(params || {})))).replace(/.{76}/g, "$&\n");
}

var gDemoAnswer = null;

function sendCommand(command, params) {
  if (!gApiHost) {
    if (gDemoAnswer) {
      setTimeout(function () {
        gDemoAnswer(command, params || {});
      }, 0);
    }
    return Promise.resolve(null);
  }
  return api("POST", "/api/v1/items/" + gDriverId + "/commands", {
    command: command,
    tParams: { DATA: encodeParams(params) },
    async: false,
  });
}

// Opened outside Composer (no apihost), the page shows #conn-warn and its own demo data: `answer(command, params)`
// stands in for the driver and calls deliver() with what the driver would push. Returns whether demo mode is on.
function demoMode(answer) {
  if (gApiHost) return false;
  gDemoAnswer = answer;
  var banner = document.getElementById("conn-warn");
  if (banner) banner.hidden = false;
  return true;
}

// A devicecommand's params as one object, { NAME: value }.
function commandParams(dc) {
  var params = {};
  var list = dc && dc.params ? dc.params.param : null;
  (Array.isArray(list) ? list : list ? [list] : []).forEach(function (p) {
    if (!p || !p.name) return;
    params[p.name] = p.value && typeof p.value === "object" && p.value.static !== undefined ? p.value.static : str(p.value);
  });
  return params;
}

var gHandlers = {};

function deliver(command, params) {
  params = params || {};
  if (command === "CONFIG_DATA" && params.properties !== undefined) showProperties(parseJson(params.properties, []));
  if (command === "PROPERTY_ERROR") {
    var refused = parseJson(params.payload, {});
    markPropertyError(refused.property, refused.error);
  }
  var handler = gHandlers[command];
  if (!handler) return;
  try {
    handler(params);
  } catch (e) {
    console.error("Handling " + command + ":", e);
  }
}

function eachDeviceCommand(evt, fn) {
  (Array.isArray(evt) ? evt : [evt]).forEach(function (item) {
    var dc = item && item.data ? item.data.devicecommand : item && item.devicecommand;
    if (dc) fn(dc);
  });
}

var gSocket = null;

// Loads socket.io from the controller and subscribes to the driver's pushes and property changes. Each push goes
// to options.handlers[command](params), and each property change made in Composer to
// options.onProperty(name, value); the properties card follows both itself. A subscription belongs to one socket
// connection, so every connect, a reconnect after a Director restart too, subscribes again and then calls
// options.onConnect() for the page to ask for its state. options.onLink(up) says when the link drops and returns.
async function connectDriver(options) {
  options = options || {};
  gHandlers = options.handlers || {};
  if (!gApiHost) return;
  try {
    if (gSocket) {
      try {
        gSocket.disconnect();
      } catch (e) {}
      gSocket = null;
    }
    var jwt = "JWT=" + gApiToken;
    if (!window.io) {
      var res = await fetch(apiOrigin() + "/socket.io/socket.io.js?" + jwt, { headers: { Authorization: "Bearer " + gApiToken } });
      eval.call(window, await res.text());
    }
    var sock = (gSocket = window.io.connect(apiOrigin(), { forceNew: true, query: jwt, transports: ["polling", "websocket"] }));
    var round = 0; // Bumped by each connect and drop, so a retry or push from an earlier one stops.
    var subscribe = async function (path, mine, listener, done) {
      if (mine !== round) return;
      var sub = await api("GET", "/api/v1/items/" + gDriverId + "/" + path + "?SubscriptionClient=" + sock.io.engine.id + "&coerce=false");
      if (mine !== round) return;
      if (!sub || !sub.subscriptionId) {
        // Refused while Director starts: asked for again.
        setTimeout(function () {
          subscribe(path, mine, listener, done);
        }, 5000);
        return;
      }
      var ev = String(sub.subscriptionId);
      if (sock.off) sock.off(ev);
      sock.on(ev, function (evt) {
        if (mine === round) listener(evt);
      });
      sock.emit("startSubscription", ev);
      if (done) done();
    };
    var onData = function (evt) {
      eachDeviceCommand(evt, function (dc) {
        if (dc.command !== "LUA_OUTPUT") deliver(dc.command, commandParams(dc));
      });
    };
    var onProperty = function (evt) {
      eachDeviceCommand(evt, function (dc) {
        if (dc.command !== "UPDATE_PROPERTY") return;
        var value = str(dc.value);
        updateProperty(dc.name, value);
        if (options.onProperty) options.onProperty(dc.name, value);
      });
    };
    sock.on("connect", function () {
      var mine = ++round;
      subscribe("properties", mine, onProperty);
      subscribe("datatoui", mine, onData, function () {
        if (options.onLink) options.onLink(true);
        if (options.onConnect) options.onConnect();
      });
    });
    sock.on("disconnect", function () {
      round++;
      if (options.onLink) options.onLink(false);
    });
  } catch (e) {
    console.error("Socket:", e);
    if (options.onLink) options.onLink(false);
    setTimeout(function () {
      connectDriver(options);
    }, 10000);
  }
}

var gTabSwitch = null;

// Shows the tab bar only from two .nav-tab elements, each naming its #panel-<name> in data-panel, and switches
// panels on a click. onSwitch(name) runs after each switch.
function initTabs(onSwitch) {
  gTabSwitch = onSwitch || null;
  var tabs = document.querySelectorAll(".nav-tab");
  var nav = document.querySelector(".nav");
  if (nav) nav.classList.toggle("multi", tabs.length > 1);
  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      switchTab(tab.dataset.panel);
    });
  });
}

function switchTab(name) {
  document.querySelectorAll(".nav-tab").forEach(function (t) {
    t.classList.toggle("active", t.dataset.panel === name);
  });
  document.querySelectorAll(".panel").forEach(function (p) {
    p.classList.toggle("active", p.id === "panel-" + name);
  });
  if (gTabSwitch) gTabSwitch(name);
}

// The properties card: a page gives it an element inside a card, and the card hides until there is something to
// show. Its fields come from CONFIG_DATA's `properties`, a change sends _SET_PROPERTY, a refusal (PROPERTY_ERROR)
// shows under its field, and a change made in Composer redraws the card.
var gProps = { el: null, list: [], errors: {} };

function initPropertiesCard(el) {
  gProps.el = el;
  el.addEventListener("change", function (e) {
    var name = e.target.dataset.prop;
    if (!name) return;
    var value = e.target.value;
    e.target.blur();
    if (gProps.errors[name]) {
      delete gProps.errors[name];
      e.target.classList.remove("input-error");
      var shown = e.target.parentNode.querySelector(".perror");
      if (shown) shown.parentNode.removeChild(shown);
    }
    sendCommand("_SET_PROPERTY", { property: name, value: value });
  });
  renderProperties();
}

function propertyControl(p, id, failed) {
  var attrs = ' id="' + id + '" data-prop="' + esc(p.name) + '"' + (failed ? ' class="input-error"' : "");
  if (p.readonly) return '<input type="text"' + attrs + ' value="' + esc(p.value) + '" title="' + esc(p.value) + '" disabled>';
  if (p.choices) {
    return (
      "<select" +
      attrs +
      ">" +
      p.choices
        .map(function (c) {
          return "<option" + (c === p.value ? " selected" : "") + ">" + esc(c) + "</option>";
        })
        .join("") +
      "</select>"
    );
  }
  if (p.minimum !== undefined) {
    return '<input type="number"' + attrs + ' min="' + esc(p.minimum) + '" max="' + esc(p.maximum) + '" step="1" value="' + esc(p.value) + '">';
  }
  return '<input type="text"' + attrs + ' value="' + esc(p.value) + '">';
}

function propertyCell(p, i) {
  var id = "prop-" + i;
  var failed = gProps.errors[p.name];
  return (
    '<div><label for="' + id + '">' + esc(p.name) + "</label>" + propertyControl(p, id, failed) +
    (failed ? '<div class="perror">' + esc(failed) + "</div>" : "") +
    (p.description ? '<div class="pdesc">' + esc(p.description) + "</div>" : "") +
    "</div>"
  );
}

function renderProperties() {
  var el = gProps.el;
  if (!el) return;
  // A push must not swap a control out from under the one being edited; the next push catches up.
  if (el.contains(document.activeElement)) return;
  var groups = [];
  gProps.list.forEach(function (p, i) {
    var g = groups[groups.length - 1];
    if (!g || g.name !== p.group) groups.push((g = { name: p.group, html: [] }));
    g.html.push(propertyCell(p, i));
  });
  var card = el.closest(".card") || el;
  card.hidden = groups.length === 0;
  el.innerHTML = groups
    .map(function (g) {
      return (g.name ? '<div class="pgroup">' + esc(g.name) + "</div>" : "") + '<div class="pfields">' + g.html.join("") + "</div>";
    })
    .join("");
}

function showProperties(list) {
  gProps.list = Array.isArray(list) ? list : [];
  renderProperties();
}

function updateProperty(name, value) {
  for (var i = 0; i < gProps.list.length; i++) {
    if (gProps.list[i].name === name) {
      gProps.list[i].value = value;
      renderProperties();
      return;
    }
  }
}

function markPropertyError(name, message) {
  if (!name) return;
  gProps.errors[name] = str(message);
  // Only its own field redraws: another may be being edited.
  gProps.list.forEach(function (p, i) {
    var control = document.getElementById("prop-" + i);
    if (p.name === name && control) control.parentNode.outerHTML = propertyCell(p, i);
  });
}
