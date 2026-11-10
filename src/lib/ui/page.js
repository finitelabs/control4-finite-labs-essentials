// The kit for a driver's custom Composer tab: its link to the driver, the banners, the tab bar, the properties card
// and demo mode. A page embeds it first in its <script>, after style.css in its <style>, with the line
// "<!-- #embed ../../../../src/lib/ui/page.js -->", then any component it uses (variables.js, expressions.js) the same
// way. Everything is on one object, Kit, so a page's own function of the same name never replaces the kit's.
//   Kit.connectDriver(options)        pushes from the driver, by command, each one object; the live-link banner
//   Kit.sendCommand(command, params)  a command to the driver's UIR handlers
//   Kit.call(command, params, answer, ms)  a command, then its answer push: the push's object, or null in time
//   Kit.follow(itemId)                another item on the same link: its pushes, commands and calls
//   Kit.initTabs(onSwitch, options)   the page's tabs, the bar shown from two; Kit.setTabs(list, active) for a set
//                                     built per state; Kit.switchTab(name); the open tab kept in the address
//   Kit.initPropertiesCard(el, options)  the properties card, for a driver whose lib.ui.tab-properties serves it;
//                                     options.exclude leaves out properties the page shows elsewhere
//   Kit.demoMode(answer)              outside Composer: the demo banner, and commands answered by the page's demo
//   Kit.deliver(command, data)        hands a demo answer to the page as a push would arrive
//   Kit.esc, Kit.str, Kit.ago         text made safe for HTML; a value as text; a time as "5 min ago"
//   Kit.listen(command, fn), Kit.demoAnswer(command, fn): a component's own pushes and demo answers, before the page's
//   Kit.apiHost, Kit.driverId, Kit.apiToken: the page's address parameters
// A driver's pushes come from lib.ui.page's send: one `json` parameter, which the kit decodes for the handler.

var Kit = (function () {
  var params = {};
  window.location.search.replace(/[?&]+([^=&]+)=([^&]*)/gi, function (m, k, v) {
    params[k] = decodeURIComponent(v);
  });
  var apiHost = params.apihost;
  var driverId = params.driverid;
  var apiToken = params.apitoken;
  // #ifndef DRIVERCENTRAL
  // Opened with a controller but no token, as a live check through the dev proxy is, the page logs in with an empty
  // login, which only the proxy's saved one fills. Composer always gives a token.
  if (apiHost && !apiToken) apiToken = devLogin();
  // #endif

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

  // A time in seconds since the epoch, as how long ago it was.
  function ago(ts) {
    if (!ts) return "";
    var s = Math.max(0, Math.floor(Date.now() / 1000 - Number(ts)));
    if (s < 5) return "just now";
    if (s < 60) return s + " s ago";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    return Math.floor(s / 86400) + " d ago";
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
    return /^https?:\/\//i.test(apiHost) ? apiHost.replace(/\/$/, "") : "https://" + apiHost;
  }

  // #ifndef DRIVERCENTRAL
  function devLogin() {
    try {
      var x = new XMLHttpRequest();
      x.open("POST", apiOrigin() + "/api/v1/localjwt", false);
      x.setRequestHeader("Content-Type", "application/json");
      x.send("{}");
      return parseJson(x.responseText, {}).token;
    } catch (e) {
      console.error("Dev login:", e);
      return undefined;
    }
  }
  // #endif

  function api(method, path, body) {
    if (!apiHost) return Promise.resolve(null);
    var opts = { method: method, headers: { Authorization: "Bearer " + apiToken, "Content-Type": "application/json" } };
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

  var demoAnswer = null;
  var demoAnswers = {};

  // A component answers its own commands in demo mode, ahead of the page's answer.
  function demoAnswerFor(command, fn) {
    demoAnswers[command] = fn;
  }

  function sendTo(id, command, params) {
    if (!apiHost) {
      var answer = demoAnswers[command] || demoAnswer;
      if (answer && id === driverId) {
        setTimeout(function () {
          answer(command, params || {});
        }, 0);
      }
      return Promise.resolve(null);
    }
    return api("POST", "/api/v1/items/" + id + "/commands", {
      command: command,
      tParams: { DATA: encodeParams(params) },
      async: false,
    });
  }

  function sendCommand(command, params) {
    return sendTo(driverId, command, params);
  }

  // The banners sit under the tab bar, or at the top of the page where it has none.
  function banner(cls, text) {
    var el = document.createElement("div");
    el.className = "banner warn " + cls;
    el.hidden = true;
    el.textContent = text;
    var nav = document.querySelector(".nav");
    if (nav && nav.parentNode) nav.parentNode.insertBefore(el, nav.nextSibling);
    else document.body.insertBefore(el, document.body.firstChild);
    return el;
  }

  // Opened outside Composer (no apihost), the page shows the demo banner and its own demo data: `answer(command,
  // params)` stands in for the driver and calls Kit.deliver with what the driver would push. Returns whether demo mode
  // is on.
  function demoMode(answer) {
    if (apiHost) return false;
    demoAnswer = answer;
    banner("kit-demo", "Demo data: open this tab from the driver in Composer to see its own.").hidden = false;
    return true;
  }

  // A devicecommand's params as one object, { NAME: value }.
  function commandParams(dc) {
    var out = {};
    var list = dc && dc.params ? dc.params.param : null;
    (Array.isArray(list) ? list : list ? [list] : []).forEach(function (p) {
      if (!p || !p.name) return;
      out[p.name] = p.value && typeof p.value === "object" && p.value.static !== undefined ? p.value.static : str(p.value);
    });
    return out;
  }

  // A push's object: lib.ui.page sends it as one `json` parameter.
  function pushData(params) {
    return params && typeof params.json === "string" ? parseJson(params.json, {}) : params || {};
  }

  var handlers = {};
  var listeners = {};
  var waiters = {};

  // A component's own pushes, ahead of the page's handler for the same command.
  function listen(command, fn) {
    (listeners[command] = listeners[command] || []).push(fn);
  }

  function wake(list, command, data) {
    var waiting = list[command];
    if (waiting) {
      delete list[command];
      waiting.forEach(function (fn) {
        fn(data);
      });
    }
    // A refusal answers every call still waiting.
    if (command === "ERROR") {
      Object.keys(list).forEach(function (k) {
        var w = list[k];
        delete list[k];
        w.forEach(function (fn) {
          fn({ error: data.message || "refused" });
        });
      });
    }
  }

  function deliver(command, data) {
    data = pushData(data);
    markLive();
    if (command === "PROPERTIES") showProperties(data.properties);
    if (command === "PROPERTY_ERROR") markPropertyError(data.property, data.error);
    (listeners[command] || []).forEach(function (fn) {
      try {
        fn(data);
      } catch (e) {
        console.error("Handling " + command + " in the kit:", e);
      }
    });
    var handler = handlers[command];
    if (handler) {
      try {
        handler(data);
      } catch (e) {
        console.error("Handling " + command + ":", e);
      }
    }
    wake(waiters, command, data);
  }

  function waitFor(list, answer, ms) {
    return new Promise(function (resolve) {
      var done = false;
      var finish = function (data) {
        if (done) return;
        done = true;
        clearTimeout(timer);
        var waiting = list[answer] || [];
        var i = waiting.indexOf(finish);
        if (i >= 0) waiting.splice(i, 1);
        if (!waiting.length) delete list[answer];
        resolve(data);
      };
      var timer = setTimeout(function () {
        finish(null);
      }, ms || 10000);
      (list[answer] = list[answer] || []).push(finish);
    });
  }

  // A request the controller did not take answers at once, rather than when the wait runs out.
  var NOT_TAKEN = { error: "the controller didn't take the command" };

  function call(command, params, answer, ms) {
    var answered = waitFor(waiters, answer, ms);
    sendCommand(command, params).then(function (r) {
      if (r === null && apiHost) wake(waiters, answer, NOT_TAKEN);
    });
    return answered;
  }

  function eachDeviceCommand(evt, fn) {
    (Array.isArray(evt) ? evt : [evt]).forEach(function (item) {
      var dc = item && item.data ? item.data.devicecommand : item && item.devicecommand;
      if (dc) fn(dc);
    });
  }

  // The live-link banner: shown when the link drops, or when no push has come within 10 s of a (re)connect, and gone
  // with the first push after it, which is fresh state.
  var live = false;
  var linkBanner = null;

  function showLink(up) {
    if (!linkBanner) {
      if (up) return;
      linkBanner = banner("kit-link", "No live connection to the driver - reconnecting…");
    }
    linkBanner.hidden = up;
  }

  function markLive() {
    if (live || !socket) return;
    live = true;
    showLink(true);
  }

  var socket = null;
  var round = 0; // Bumped by each connect and drop, so a retry or push from an earlier one stops.
  var links = {};

  // Subscribes to an item's pushes on the socket: Director keys a subscription to the socket's engine id, so every
  // connect needs a fresh one. A refusal while Director starts is asked for again.
  async function subscribe(id, path, mine, listener, done) {
    var sock = socket;
    if (!sock || mine !== round) return;
    var sub = await api("GET", "/api/v1/items/" + id + "/" + path + "?SubscriptionClient=" + sock.io.engine.id + "&coerce=false");
    if (mine !== round) return;
    if (!sub || !sub.subscriptionId) {
      setTimeout(function () {
        subscribe(id, path, mine, listener, done);
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
  }

  // Loads socket.io from the controller and subscribes to the driver's pushes and property changes. Each push goes
  // to options.handlers[command](data), and each property change made in Composer to options.onProperty(name, value);
  // the properties card follows both itself. Every connect, a reconnect after a Director restart too, subscribes again
  // and then calls options.onConnect() for the page to ask for its state. options.poll, { command, every }, sends a
  // command on a timer, as a driver that pushes only while a page asks needs. In demo mode (Kit.demoMode first) it
  // asks the same, and the page's demo answer replies.
  async function connectDriver(options) {
    options = options || {};
    handlers = options.handlers || {};
    if (!apiHost) {
      // Demo mode: the page's demo answer stands in for the driver, asked what a connect asks.
      setTimeout(function () {
        if (props.el) sendCommand("_GET_PROPERTIES");
        if (options.onConnect) options.onConnect();
      }, 0);
      return;
    }
    setTimeout(function () {
      if (!live) showLink(false);
    }, 10000);
    if (options.poll) {
      setInterval(function () {
        sendCommand(options.poll.command);
      }, options.poll.every);
    }
    try {
      if (socket) {
        try {
          socket.disconnect();
        } catch (e) {}
        socket = null;
      }
      var jwt = "JWT=" + apiToken;
      if (!window.io) {
        var res = await fetch(apiOrigin() + "/socket.io/socket.io.js?" + jwt, { headers: { Authorization: "Bearer " + apiToken } });
        eval.call(window, await res.text());
      }
      var sock = (socket = window.io.connect(apiOrigin(), { forceNew: true, query: jwt, transports: ["polling", "websocket"] }));
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
          askProperties();
          if (options.onProperty) options.onProperty(dc.name, value);
        });
      };
      sock.on("connect", function () {
        var mine = ++round;
        live = false;
        subscribe(driverId, "properties", mine, onProperty);
        subscribe(driverId, "datatoui", mine, onData, function () {
          linked = true;
          if (props.el) sendCommand("_GET_PROPERTIES");
          if (options.onConnect) options.onConnect();
        });
        Object.keys(links).forEach(function (id) {
          links[id].subscribed = false;
        });
      });
      sock.on("disconnect", function () {
        round++;
        live = false;
        linked = false;
        showLink(false);
      });
    } catch (e) {
      console.error("Socket:", e);
      showLink(false);
      setTimeout(function () {
        connectDriver(options);
      }, 10000);
    }
  }

  // Another item on the same link: link.on(fn) gets each of its pushes as fn(command, data), link.send and link.call
  // reach it as Kit.sendCommand and Kit.call reach the page's own driver, and link.open() makes its subscription,
  // resolving whether it holds. Director documents no way to end one, so a link is kept for the socket's life.
  function follow(id) {
    id = String(id);
    if (links[id]) return links[id];
    var listeners = [];
    var linkWaiters = {};
    var link = {
      id: id,
      subscribed: false,
      on: function (fn) {
        listeners.push(fn);
      },
      open: function () {
        if (link.subscribed) return Promise.resolve(true);
        if (!socket || !socket.io || !socket.io.engine) return Promise.resolve(false);
        return new Promise(function (resolve) {
          var timer = setTimeout(function () {
            resolve(false);
          }, 10000);
          subscribe(
            id,
            "datatoui",
            round,
            function (evt) {
              eachDeviceCommand(evt, function (dc) {
                if (dc.command === "LUA_OUTPUT") return;
                var data = pushData(commandParams(dc));
                listeners.forEach(function (fn) {
                  fn(dc.command, data);
                });
                wake(linkWaiters, dc.command, data);
              });
            },
            function () {
              clearTimeout(timer);
              link.subscribed = true;
              resolve(true);
            }
          );
        });
      },
      send: function (command, params) {
        return sendTo(id, command, params);
      },
      call: function (command, params, answer, ms) {
        var answered = waitFor(linkWaiters, answer, ms);
        sendTo(id, command, params).then(function (r) {
          if (r === null && apiHost) wake(linkWaiters, answer, NOT_TAKEN);
        });
        return answered;
      },
    };
    return (links[id] = link);
  }

  // The tabs: each .nav-tab names its #panel-<name> in data-panel. The bar shows from two tabs. onSwitch(name, detail)
  // runs after each switch; with options.hash the open tab is kept in the address, as #name or #name/detail, so a
  // reload or a link opens it.
  var tabSwitch = null;
  var hashTabs = false;

  function bindTabs() {
    var tabs = document.querySelectorAll(".nav-tab");
    var nav = document.querySelector(".nav");
    if (nav) nav.classList.toggle("multi", tabs.length > 1);
    tabs.forEach(function (tab) {
      tab.onclick = function () {
        switchTab(tab.dataset.panel);
      };
    });
  }

  function hashTab() {
    var parts = location.hash.replace(/^#/, "").split("/");
    return { name: parts[0], detail: parts.slice(1).join("/") };
  }

  function initTabs(onSwitch, options) {
    tabSwitch = onSwitch || null;
    hashTabs = !!(options && options.hash);
    bindTabs();
    if (!hashTabs) return;
    var open = hashTab();
    if (open.name && tabExists(open.name)) show(open.name, open.detail);
    // Back, forward or an edited address; a switch's own change is already shown.
    window.addEventListener("hashchange", function () {
      var now = hashTab();
      if (now.name && tabExists(now.name) && (now.name !== shown.name || now.detail !== shown.detail)) show(now.name, now.detail);
    });
  }

  // A tab set built per state: list is [[name, label], ...].
  function setTabs(list, active) {
    var nav = document.querySelector(".nav");
    if (!nav) return;
    nav.innerHTML = list
      .map(function (t) {
        return '<div class="nav-tab' + (t[0] === active ? " active" : "") + '" data-panel="' + esc(t[0]) + '">' + esc(t[1]) + "</div>";
      })
      .join("");
    bindTabs();
  }

  function tabExists(name) {
    return !!document.querySelector('.nav-tab[data-panel="' + name + '"]') || !!document.getElementById("panel-" + name);
  }

  var shown = { name: null, detail: "" };

  function show(name, detail) {
    shown = { name: name, detail: detail || "" };
    document.querySelectorAll(".nav-tab").forEach(function (t) {
      t.classList.toggle("active", t.dataset.panel === name);
    });
    // A page that renders one panel per tab itself has no #panel-<name>, and its panel stays shown.
    if (document.getElementById("panel-" + name)) {
      document.querySelectorAll(".panel").forEach(function (p) {
        p.classList.toggle("active", p.id === "panel-" + name);
      });
    }
    if (tabSwitch) tabSwitch(name, detail || "");
  }

  function switchTab(name, detail) {
    if (hashTabs) {
      var want = "#" + name + (detail ? "/" + detail : "");
      if (location.hash !== want) location.hash = want;
    }
    show(name, detail);
  }

  // Changes only the open tab's detail in the address, without a switch.
  function setDetail(detail) {
    if (!hashTabs) return;
    var name = shown.name || hashTab().name;
    if (!name) return;
    shown.detail = detail || "";
    history.replaceState(null, "", "#" + name + (detail ? "/" + detail : ""));
  }

  // The properties card: a page gives it an element inside a card, and the card hides until there is something to
  // show. It asks the driver for the properties on each connect and after each change, a change sends _SET_PROPERTY,
  // a refusal (PROPERTY_ERROR) shows under its field, and a change made in Composer redraws the card at once. A page that redraws the
  // card's element calls initPropertiesCard again with the new one.
  var props = { el: null, list: [], errors: {}, exclude: [] };
  var linked = false; // the driver's pushes are subscribed

  // options.exclude names properties the page shows elsewhere, which the card leaves out.
  function initPropertiesCard(el, options) {
    props.el = el;
    if (options && options.exclude) props.exclude = options.exclude;
    // A card set up after the connect (a page that draws it with its first state) asks for itself.
    if (!props.list.length && (linked || !apiHost)) askProperties();
    el.classList.add("kit-props");
    el.addEventListener("change", function (e) {
      var name = e.target.dataset.prop;
      if (!name) return;
      var value = e.target.value;
      e.target.blur();
      if (props.errors[name]) {
        delete props.errors[name];
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
    var failed = props.errors[p.name];
    return (
      '<div><label for="' + id + '">' + esc(p.name) + "</label>" + propertyControl(p, id, failed) +
      (failed ? '<div class="perror">' + esc(failed) + "</div>" : "") +
      (p.description ? '<div class="pdesc">' + esc(p.description) + "</div>" : "") +
      "</div>"
    );
  }

  function renderProperties() {
    var el = props.el;
    if (!el) return;
    // A push must not swap a control out from under the one being edited; the next push catches up.
    if (el.contains(document.activeElement)) return;
    var groups = [];
    props.list.forEach(function (p, i) {
      if (props.exclude.indexOf(p.name) >= 0) return;
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

  // A change can change the list too (a Support Code widens Log Level's choices), so the card asks again, once for a
  // burst of changes.
  var asking = null;
  function askProperties() {
    if (!props.el || asking) return;
    asking = setTimeout(function () {
      asking = null;
      sendCommand("_GET_PROPERTIES");
    }, 300);
  }

  function showProperties(list) {
    props.list = Array.isArray(list) ? list : [];
    renderProperties();
  }

  function updateProperty(name, value) {
    for (var i = 0; i < props.list.length; i++) {
      if (props.list[i].name === name) {
        props.list[i].value = value;
        renderProperties();
        return;
      }
    }
  }

  function markPropertyError(name, message) {
    if (!name) return;
    props.errors[name] = str(message);
    // Only its own field redraws: another may be being edited.
    props.list.forEach(function (p, i) {
      var control = document.getElementById("prop-" + i);
      if (p.name === name && control) control.parentNode.outerHTML = propertyCell(p, i);
    });
  }

  return {
    apiHost: apiHost,
    driverId: driverId,
    apiToken: apiToken,
    str: str,
    esc: esc,
    ago: ago,
    api: api,
    encodeParams: encodeParams,
    sendCommand: sendCommand,
    call: call,
    follow: follow,
    listen: listen,
    demoAnswer: demoAnswerFor,
    demoMode: demoMode,
    deliver: deliver,
    connectDriver: connectDriver,
    initTabs: initTabs,
    setTabs: setTabs,
    switchTab: switchTab,
    setDetail: setDetail,
    initPropertiesCard: initPropertiesCard,
    showProperties: showProperties,
    markPropertyError: markPropertyError,
    // For the kit's own tests.
    _commandParams: commandParams,
    _properties: props,
  };
})();
