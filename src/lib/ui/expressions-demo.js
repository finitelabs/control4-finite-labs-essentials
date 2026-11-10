// The expression editor's demo previews, for a page that embeds expressions.js and wants them: outside Composer the
// kit answers _EVAL_EXPRESSION itself, the way lib.ui.expression-tab does, for the part of Lua an expression mostly
// uses, so a demo preview takes the same path to the page as a real one. A page embeds it after expressions.js; one
// that doesn't has its demo-mode _EVAL_EXPRESSION answered by its own Kit.demoMode answer, as any command is.
//   Kit.expressionDemo(devices, variablesById, options)  the devices and variables a demo preview reads, as
//       Kit.devices.demo takes them; options.hold(expression, mode, answer) and options.extra(answer, mode,
//       expression) stand in for the driver's

(function () {
  // A token as the driver reads it (lib/expressions.lua's PARAM_PATTERN), its device and variable captured.
  var TOKEN_CAPTURE = /PARAM\s*\{\s*([\s\S]*?)\s*,\s*([\s\S]*?)\s*\}/.source;
  var demo = { devices: [], variables: {} };
  var DEMO_LIMIT = "Outside Composer, the preview tries only part of the syntax, and not this part.";
  var LIMIT = {};

  // The devices and variables a demo preview reads, as Kit.devices.demo takes them, so a page hands both the same data.
  // options.hold(expression, mode, answer) and options.extra(answer, mode, expression) stand in for the driver's.
  function expressionDemo(devices, variablesById, options) {
    options = options || {};
    demo = { devices: devices || [], variables: variablesById || {}, hold: options.hold, extra: options.extra };
  }

  function LuaError(kind, message) {
    this.kind = kind;
    this.message = message;
  }

  function luaType(v) {
    if (v === null || v === undefined) return "nil";
    if (typeof v === "object") return "table";
    return typeof v;
  }

  // As Lua's tostring writes a number: %.14g.
  function luaNumber(n) {
    if (n !== n) return "nan";
    if (n === Infinity) return "inf";
    if (n === -Infinity) return "-inf";
    if (n === 0) return 1 / n < 0 ? "-0" : "0";
    var e = n.toExponential(13);
    var at = e.indexOf("e");
    var x = Number(e.slice(at + 1));
    var trim = function (s) {
      return s.indexOf(".") < 0 ? s : s.replace(/0+$/, "").replace(/\.$/, "");
    };
    if (x < -4 || x >= 14) return trim(e.slice(0, at)) + "e" + (x < 0 ? "-" : "+") + (Math.abs(x) < 10 ? "0" : "") + Math.abs(x);
    return trim(n.toFixed(13 - x));
  }

  function luaString(v) {
    var type = luaType(v);
    if (type === "number") return luaNumber(v);
    if (type === "string") return v;
    if (type === "nil") return "nil";
    if (type === "boolean") return String(v);
    return type + ": 0x0";
  }

  // As Lua reads text as a number: in arithmetic, and for tonumber.
  function luaToNumber(v) {
    if (typeof v === "number") return v;
    if (typeof v !== "string") return null;
    var m = /^\s*([-+]?)(?:0[xX]([0-9a-fA-F]+)|((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|(inf(?:inity)?|nan))\s*$/i.exec(v);
    if (!m) return null;
    var n = m[2] ? parseInt(m[2], 16) : m[3] ? parseFloat(m[3]) : /^n/i.test(m[4]) ? NaN : Infinity;
    return m[1] === "-" ? -n : n;
  }

  // A variable's text as the driver binds it: true, false and finite numbers as themselves, the rest as text.
  function typedValue(text) {
    if (text === "true") return true;
    if (text === "false") return false;
    var n = luaToNumber(text);
    return n !== null && isFinite(n) ? n : text;
  }

  function truthy(v) {
    return v !== null && v !== undefined && v !== false;
  }

  function fail(message) {
    throw new LuaError("runtime", message);
  }

  function checkNumber(args, i, name) {
    var n = luaToNumber(args[i]);
    if (n === null) fail("bad argument #" + (i + 1) + " to '" + name + "' (number expected, got " + (i < args.length ? luaType(args[i]) : "no value") + ")");
    return n;
  }

  function checkString(args, i, name) {
    var v = args[i];
    if (typeof v === "number") return luaNumber(v);
    if (typeof v !== "string") fail("bad argument #" + (i + 1) + " to '" + name + "' (string expected, got " + (i < args.length ? luaType(v) : "no value") + ")");
    return v;
  }

  function numeric(name, fn) {
    return function (args) {
      return fn(checkNumber(args, 0, name), args);
    };
  }

  function extreme(name, pick) {
    return function (args) {
      var best = checkNumber(args, 0, name);
      for (var i = 1; i < args.length; i++) best = pick(best, checkNumber(args, i, name));
      return best;
    };
  }

  function limited() {
    throw LIMIT;
  }

  var MATH = {
    abs: numeric("abs", Math.abs),
    ceil: numeric("ceil", Math.ceil),
    floor: numeric("floor", Math.floor),
    sqrt: numeric("sqrt", Math.sqrt),
    exp: numeric("exp", Math.exp),
    log: numeric("log", Math.log),
    log10: numeric("log10", Math.log10),
    sin: numeric("sin", Math.sin),
    cos: numeric("cos", Math.cos),
    tan: numeric("tan", Math.tan),
    asin: numeric("asin", Math.asin),
    acos: numeric("acos", Math.acos),
    atan: numeric("atan", Math.atan),
    sinh: numeric("sinh", Math.sinh),
    cosh: numeric("cosh", Math.cosh),
    tanh: numeric("tanh", Math.tanh),
    deg: numeric("deg", function (x) {
      return (x * 180) / Math.PI;
    }),
    rad: numeric("rad", function (x) {
      return (x * Math.PI) / 180;
    }),
    min: extreme("min", Math.min),
    max: extreme("max", Math.max),
    fmod: function (args) {
      var a = checkNumber(args, 0, "fmod");
      return a % checkNumber(args, 1, "fmod");
    },
    pow: function (args) {
      return Math.pow(checkNumber(args, 0, "pow"), checkNumber(args, 1, "pow"));
    },
    atan2: function (args) {
      return Math.atan2(checkNumber(args, 0, "atan2"), checkNumber(args, 1, "atan2"));
    },
    random: limited,
    randomseed: limited,
    frexp: limited,
    ldexp: limited,
    modf: limited,
    pi: Math.PI,
    huge: Infinity,
  };

  var STRING = {
    lower: function (args) {
      return checkString(args, 0, "lower").toLowerCase();
    },
    upper: function (args) {
      return checkString(args, 0, "upper").toUpperCase();
    },
    len: function (args) {
      return checkString(args, 0, "len").length;
    },
    reverse: function (args) {
      return checkString(args, 0, "reverse").split("").reverse().join("");
    },
    rep: function (args) {
      var s = checkString(args, 0, "rep");
      var n = checkNumber(args, 1, "rep");
      return n > 0 ? new Array(Math.floor(n) + 1).join(s) : "";
    },
    sub: function (args) {
      var s = checkString(args, 0, "sub");
      var len = s.length;
      var at = function (i, fallback) {
        var n = args.length > i && args[i] !== null ? Math.floor(checkNumber(args, i, "sub")) : fallback;
        return n < 0 ? Math.max(len + n + 1, 0) : n;
      };
      var from = Math.max(at(1, 1), 1);
      var to = Math.min(at(2, -1), len);
      return from > to ? "" : s.slice(from - 1, to);
    },
    byte: limited,
    "char": limited,
    dump: limited,
    find: limited,
    format: limited,
    gmatch: limited,
    gsub: limited,
    match: limited,
  };

  function demoDevice(id) {
    var found = null;
    demo.devices.forEach(function (d) {
      if (String(d.id) === String(id)) found = d;
    });
    return found;
  }

  // The device a token names, its entry in the list and its variable. A row's deviceId is the member owning it, which
  // can be a proxy listed under its driver's entry.
  function demoFind(device, ref) {
    var found = { known: false, entry: null, variable: null };
    if (!/^\d+$/.test(device)) return found;
    found.entry = demoDevice(device);
    found.known = !!found.entry;
    Object.keys(demo.variables).forEach(function (entryId) {
      (demo.variables[entryId] || []).forEach(function (v) {
        if (String(v.deviceId != null ? v.deviceId : entryId) !== device) return;
        found.known = true;
        found.entry = found.entry || demoDevice(entryId);
        if (!found.variable && (/^\d+$/.test(ref) ? String(v.id) === ref : v.name === ref)) found.variable = v;
      });
    });
    return found;
  }

  function round(args) {
    // numDecimalPlaces or 0
    var places = truthy(args[1]) ? args[1] : 0;
    var mult = arith("^", 10, places, null, { local: "numDecimalPlaces" });
    return Math.floor(arith("*", args[0], mult, { local: "num" }, null) + 0.5) / mult;
  }

  function temperature(convert) {
    return function (args) {
      return typeof args[0] === "number" ? round([convert(args[0]), 1]) : null;
    };
  }

  function deviceField(field) {
    return function (args) {
      var device = luaToNumber(args[0]) !== null ? demoDevice(luaToNumber(args[0])) : null;
      return device && device[field] ? device[field] : luaString(args[0]);
    };
  }

  var ENV = {
    abs: MATH.abs,
    ceil: MATH.ceil,
    floor: MATH.floor,
    sqrt: MATH.sqrt,
    min: MATH.min,
    max: MATH.max,
    pi: Math.PI,
    huge: Infinity,
    round: round,
    c2f: temperature(function (c) {
      return c * (9 / 5) + 32;
    }),
    f2c: temperature(function (f) {
      return (f - 32) * (5 / 9);
    }),
    tonumber: function (args) {
      if (args.length < 2 || args[1] === null) return luaToNumber(args[0]);
      var base = checkNumber(args, 1, "tonumber");
      var text = checkString(args, 0, "tonumber").trim().toLowerCase();
      var digits = "0123456789abcdefghijklmnopqrstuvwxyz".slice(0, base);
      for (var i = 0; i < text.length; i++) if (digits.indexOf(text.charAt(i)) < 0) return null;
      return text ? parseInt(text, base) : null;
    },
    tostring: function (args) {
      return luaString(args[0]);
    },
    type: function (args) {
      return luaType(args[0]);
    },
    device_name: deviceField("name"),
    room_name: deviceField("roomName"),
    math: MATH,
    string: STRING,
  };

  // What a value is called in Lua's error, as the compiled code knows it.
  function describe(node, v) {
    var what = "a " + luaType(v) + " value";
    if (!node) return what;
    if (node.local) return "local '" + node.local + "' (" + what + ")";
    if (node.k === "name") return "global '" + node.name + "' (" + what + ")";
    if (node.k === "var") return "field '?' (" + what + ")";
    if (node.k === "index" && node.field) return "field '" + node.field + "' (" + what + ")";
    if (node.k === "method") return "method '" + node.field + "' (" + what + ")";
    return what;
  }

  function arith(op, a, b, nodeA, nodeB) {
    var x = luaToNumber(a);
    var y = luaToNumber(b);
    if (x === null) fail("attempt to perform arithmetic on " + describe(nodeA, a));
    if (y === null) fail("attempt to perform arithmetic on " + describe(nodeB, b));
    if (op === "+") return x + y;
    if (op === "-") return x - y;
    if (op === "*") return x * y;
    if (op === "/") return x / y;
    if (op === "%") return x - Math.floor(x / y) * y;
    return Math.pow(x, y);
  }

  function less(a, b, orEqual) {
    var ta = luaType(a);
    var tb = luaType(b);
    if (ta === tb && (ta === "number" || ta === "string")) return orEqual ? a <= b : a < b;
    fail(ta === tb ? "attempt to compare two " + ta + " values" : "attempt to compare " + ta + " with " + tb);
  }

  function index(obj, key, node) {
    var type = luaType(obj);
    // A string's methods are the string library's, as its metatable gives them.
    var table = type === "string" ? STRING : type === "table" ? obj : null;
    if (!table) fail("attempt to index " + describe(node, obj));
    return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : null;
  }

  function run(node) {
    switch (node.k) {
      case "val":
        return node.v;
      case "var":
        return node.v;
      case "name":
        return Object.prototype.hasOwnProperty.call(ENV, node.name) ? ENV[node.name] : null;
      case "index":
        return index(run(node.obj), node.field || run(node.key), node.obj);
      case "call":
      case "method": {
        var self = node.k === "method" ? run(node.obj) : null;
        var fn = node.k === "method" ? index(self, node.field, node.obj) : run(node.fn);
        var args = node.args.map(run);
        if (node.k === "method") args.unshift(self);
        if (typeof fn !== "function") fail("attempt to call " + describe(node.k === "method" ? node : node.fn, fn));
        var out = fn(args);
        return out === undefined ? null : out;
      }
      case "not":
        return !truthy(run(node.a));
      case "neg": {
        var operand = run(node.a);
        var n = luaToNumber(operand);
        if (n === null) fail("attempt to perform arithmetic on " + describe(node.a, operand));
        return -n;
      }
      case "len": {
        var v = run(node.a);
        if (typeof v !== "string") fail("attempt to get length of " + describe(node.a, v));
        return v.length;
      }
    }
    var op = node.op;
    if (op === "and" || op === "or") {
      var left = run(node.a);
      return truthy(left) === (op === "or") ? left : run(node.b);
    }
    var a = run(node.a);
    var b = run(node.b);
    if (op === "==") return luaType(a) === luaType(b) && a === b;
    if (op === "~=") return !(luaType(a) === luaType(b) && a === b);
    // Lua compiles a > b as b < a, and its error names them that way round.
    if (op === "<") return less(a, b, false);
    if (op === "<=") return less(a, b, true);
    if (op === ">") return less(b, a, false);
    if (op === ">=") return less(b, a, true);
    if (op === "..") {
      var bad = typeof a === "string" || typeof a === "number" ? (typeof b === "string" || typeof b === "number" ? null : [node.b, b]) : [node.a, a];
      if (bad) fail("attempt to concatenate " + describe(bad[0], bad[1]));
      return luaString(a) + luaString(b);
    }
    return arith(op, a, b, node.a, node.b);
  }

  // ─── The demo's parser, Lua 5.1's grammar for one returned expression ──────

  var KEYWORDS = /^(?:and|break|do|else|elseif|end|false|for|function|if|in|local|nil|not|or|repeat|return|then|true|until|while)$/;
  var BINARY = { or: [1, 1], and: [2, 2], "<": [3, 3], ">": [3, 3], "<=": [3, 3], ">=": [3, 3], "~=": [3, 3], "==": [3, 3], "..": [5, 4], "+": [6, 6], "-": [6, 6], "*": [7, 7], "/": [7, 7], "%": [7, 7], "^": [10, 9] };
  var ESCAPES = { n: "\n", t: "\t", r: "\r", a: "\x07", b: "\b", f: "\f", v: "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n" };

  function syntax(message, tok) {
    throw new LuaError("compile", message + " near '" + tok.s + "'");
  }

  function lexString(src, at) {
    var quote = src.charAt(at);
    var out = "";
    var i = at + 1;
    while (i < src.length) {
      var c = src.charAt(i);
      if (c === quote) return { t: "str", v: out, s: src.slice(at, i + 1), end: i + 1 };
      if (c === "\n") syntax("unfinished string", { s: src.slice(at, i) });
      if (c === "\\") {
        var next = src.charAt(i + 1);
        var digits = /^\d{1,3}/.exec(src.slice(i + 1));
        if (digits) {
          out += String.fromCharCode(Number(digits[0]));
          i += 1 + digits[0].length;
          continue;
        }
        out += ESCAPES[next] !== undefined ? ESCAPES[next] : next;
        i += 2;
        continue;
      }
      out += c;
      i++;
    }
    syntax("unfinished string", { s: "<eof>" });
  }

  function lex(src, lookup) {
    var out = [];
    var at = 0;
    var m;
    while (at <= src.length) {
      var rest = src.slice(at);
      if ((m = /^(?:\s+|--(?!\[=*\[)[^\n]*)/.exec(rest))) {
        at += m[0].length;
        continue;
      }
      if (!rest) break;
      if (/^(?:--)?\[=*\[/.test(rest)) throw LIMIT;
      if ((m = new RegExp("^" + TOKEN_CAPTURE).exec(rest))) {
        out.push({ t: "var", v: typedValue(lookup(m[1], m[2])), s: m[0] });
      } else if ((m = /^\.?\d[\d.]*(?:[eE][+-]?)?\w*/.exec(rest))) {
        if (!/^(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)$/.test(m[0])) syntax("malformed number", { s: m[0] });
        out.push({ t: "num", v: luaToNumber(m[0]), s: m[0] });
      } else if (rest.charAt(0) === '"' || rest.charAt(0) === "'") {
        var str = lexString(src, at);
        // A variable inside quotes is written into the text, as the driver does.
        str.v = str.v.replace(new RegExp(TOKEN_CAPTURE, "g"), function (whole, device, ref) {
          return lookup(device, ref);
        });
        out.push(str);
        at = str.end;
        continue;
      } else if ((m = /^[A-Za-z_]\w*/.exec(rest))) {
        out.push({ t: KEYWORDS.test(m[0]) ? "kw" : "name", s: m[0] });
      } else {
        // Lua's lexer passes any other character on as a token of its own, for the parser to refuse.
        m = /^(?:\.\.\.|\.\.|==|~=|<=|>=|[\s\S])/.exec(rest);
        out.push({ t: "op", s: m[0] });
      }
      at += m[0].length;
    }
    out.push({ t: "eof", s: "<eof>" });
    return out;
  }

  function parse(tokens) {
    var i = 0;
    var peek = function () {
      return tokens[i];
    };
    var next = function () {
      return tokens[i++];
    };
    var is = function (s) {
      var tok = tokens[i];
      return (tok.t === "op" || tok.t === "kw") && tok.s === s;
    };
    var expect = function (s) {
      if (!is(s)) syntax("'" + s + "' expected", peek());
      next();
    };

    function args() {
      if (!is("(")) throw LIMIT;
      next();
      var list = [];
      if (!is(")")) {
        list.push(expr(0));
        while (is(",")) {
          next();
          list.push(expr(0));
        }
      }
      expect(")");
      return list;
    }

    function primary() {
      var tok = peek();
      var node;
      if (tok.t === "name") {
        next();
        node = { k: "name", name: tok.s };
      } else if (tok.t === "var") {
        next();
        node = { k: "var", v: tok.v };
      } else if (is("(")) {
        next();
        node = expr(0);
        expect(")");
      } else {
        syntax("unexpected symbol", tok);
      }
      for (;;) {
        if (is(".") || is(":")) {
          var method = next().s === ":";
          var name = peek();
          if (name.t !== "name") syntax("<name> expected", name);
          next();
          node = method ? { k: "method", obj: node, field: name.s, args: args() } : { k: "index", obj: node, field: name.s };
        } else if (is("[")) {
          next();
          node = { k: "index", obj: node, key: expr(0) };
          expect("]");
        } else if (is("(")) {
          node = { k: "call", fn: node, args: args() };
        } else if (peek().t === "str" || is("{")) {
          throw LIMIT;
        } else {
          return node;
        }
      }
    }

    function simple() {
      var tok = peek();
      if (tok.t === "num" || tok.t === "str") {
        next();
        return { k: "val", v: tok.v };
      }
      if (is("nil") || is("true") || is("false")) {
        next();
        return { k: "val", v: tok.s === "nil" ? null : tok.s === "true" };
      }
      if (is("{") || is("function") || is("...")) throw LIMIT;
      return primary();
    }

    function expr(limit) {
      var node;
      if (is("not") || is("-") || is("#")) {
        var op = next().s;
        node = { k: op === "not" ? "not" : op === "-" ? "neg" : "len", a: expr(8) };
      } else {
        node = simple();
      }
      for (;;) {
        var tok = peek();
        var prio = (tok.t === "op" || tok.t === "kw") && Object.prototype.hasOwnProperty.call(BINARY, tok.s) && BINARY[tok.s];
        if (!prio || prio[0] <= limit) return node;
        next();
        node = { k: "bin", op: tok.s, a: node, b: expr(prio[1]) };
      }
    }

    // return e1, e2, ...: the first is the result.
    var first = expr(0);
    while (is(",")) {
      next();
      expr(0);
    }
    if (is(";")) next();
    if (peek().t !== "eof") syntax("'<eof>' expected", peek());
    return first;
  }

  // The chunk's name in an error, as Lua writes a string source's.
  function chunk(text) {
    var source = "return " + text;
    var line = source.split("\n")[0];
    return '[string "' + (line.length < source.length || line.length > 45 ? line.slice(0, 42) + "..." : line) + '"]:1: ';
  }

  function demoEvaluate(mode, text) {
    var problem = "";
    var find = function (device, ref) {
      var found = demoFind(device, ref);
      if (!found.variable && !problem) problem = found.known ? "variable " + ref + " not found on device " + device : "device " + device + " not found";
      return found;
    };
    var tokens = new RegExp(TOKEN_CAPTURE, "g");
    var answer = {
      rendered: text.replace(tokens, function (m, device, ref) {
        var found = find(device, ref);
        var d = found.entry;
        var label = d ? (d.roomName ? d.roomName + " > " : "") + d.name : "Device " + device;
        return "[" + label + " > " + (found.variable ? found.variable.name : ref) + "]";
      }),
      result: "",
    };
    answer.substituted = text.replace(tokens, function (m, device, ref) {
      var found = find(device, ref);
      return found.variable ? Kit.str(found.variable.value) : "ERROR_VARIABLE_NOT_FOUND";
    });
    answer.error = problem;
    if (problem) return answer;
    if (mode === "string") {
      answer.result = answer.substituted;
      return answer;
    }
    try {
      var tree = parse(
        lex(text, function (device, ref) {
          var found = find(device, ref).variable;
          return found ? Kit.str(found.value) : "ERROR_VARIABLE_NOT_FOUND";
        })
      );
      var result = run(tree);
      var want = mode === "condition" ? "boolean" : "number";
      if (luaType(result) !== want) answer.error = "result is not a " + want + " (got " + luaType(result) + ")";
      else answer.result = luaString(result);
    } catch (e) {
      if (e === LIMIT) answer.error = DEMO_LIMIT;
      else if (e instanceof LuaError) answer.error = e.kind + " error: " + chunk(text) + e.message;
      else throw e;
    }
    return answer;
  }

  Kit.demoAnswer("_EVAL_EXPRESSION", function (command, params) {
    var mode = Kit.str(params.mode) || "equation";
    var expression = Kit.str(params.expression);
    var answer = demoEvaluate(mode, expression);
    var held = demo.hold ? demo.hold(expression, mode, answer) : "";
    if (held) {
      answer = { rendered: answer.rendered, substituted: "", result: "", error: Kit.str(held), hold: true };
    }
    var extra = demo.extra ? demo.extra(answer, mode, expression) || {} : {};
    Object.keys(extra).forEach(function (key) {
      if (answer[key] === undefined) answer[key] = extra[key];
    });
    answer.id = params.id;
    Kit.deliver("EVAL_RESULT", answer);
  });

  Kit.expressionDemo = expressionDemo;
  // For the kit's own tests.
  Kit._demoEvaluate = demoEvaluate;
})();
