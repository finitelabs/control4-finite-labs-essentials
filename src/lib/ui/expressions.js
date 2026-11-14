// The expression editor, for a page that embeds page.js: a textarea over a <pre> that colors the same text, its syntax
// help, how many variables it reads, and a live preview the driver's lib.ui.expression-tab evaluates. A page embeds it
// after page.js, and expressions.css after style.css, the same way.
//   Kit.expressionEditor(textarea, options)  wraps the textarea and returns the editor:
//       value(), setValue(text), setMode(mode), insert(text), sync(), preview(now), used(), hold
//   Kit.expressionHelp(options)              a help panel of its own, for one that serves several fields
//   Kit.expressionError(raw, text, rendered, label)  an engine error as a plain sentence
// The modes: equation comes out a number, condition true or false, string is the text with each variable's value in
// it, and text colors only the variables and is never evaluated. In demo mode a preview goes to the page's demo answer.
//
// Editor options:
//   mode                 "equation" (the default), "condition", "string" or "text"
//   escapes              colors \r \n \t \0 \\ and \xNN in string and text modes
//   singleLine           Enter adds no line, and value() reads a pasted line break as a space
//   onInput(text)        after each edit
//   preview              the element the preview fills, ahead of what the page put in it, or false
//   previewWhen(text)    whether this text is evaluated: by default, whenever it isn't blank
//   onResult(result, editor)  each answer to the text as it stands, result.message its error in plain words
//   label                the field's name in a plain-language error
//   watch                the element that says how many variables the text reads
//   help                 { toggle, panel, wrap, sections }: the button, the panel the kit fills, what shows and hides
//                        with it (the panel itself by default) and its sections, each a key of the kit's or
//                        { title, html }; by default the kit's reference for the mode
// editor.hold is the plain reason the driver refuses the text whatever its variables hold, for Save to wait on, or "".

(function () {
  // Every name the sandbox (lib/expression-sandbox.lua) gives an expression; math and string are libraries.
  var NAMES = ["abs", "ceil", "floor", "sqrt", "min", "max", "round", "pi", "huge", "c2f", "f2c", "device_name", "room_name", "json", "tonumber", "tostring", "type"];
  var LIBRARIES = ["math", "string"];
  var WORDS = ["and", "or", "not", "true", "false"];

  var TOKEN = /PARAM\s*\{[^}]*\}/.source;
  var CODE = new RegExp(
    "(" + TOKEN + ")" +
      "|(" + /"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'/.source + ")" +
      "|((?:" + LIBRARIES.join("|") + ")\\.[A-Za-z_]\\w*|\\b(?:" + NAMES.concat(WORDS).join("|") + ")\\b)" +
      // Any other name, left plain, so a digit in it isn't colored as a number.
      "|([A-Za-z_]\\w*)" +
      "|(" + /0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?/.source + ")" +
      "|(" + /<=?|>=?|==|~=|\.\.|[+\-*\/%^#(),]/.source + ")"
  ).source;
  var CODE_CLASSES = [null, "tok", "str", "fn", "", "num", "op"];
  var TEXT = "(" + TOKEN + ")";
  var ESCAPED = TEXT + "|(" + /\\x[0-9a-fA-F]{2}|\\[rnt0\\]/.source + ")";
  var TEXT_CLASSES = [null, "tok", "esc"];
  var USED = /PARAM\s*\{\s*([^,}]*?)\s*,\s*([^}]*?)\s*\}/g;

  function evaluated(mode) {
    return mode === "equation" || mode === "condition";
  }

  function paint(text, source, classes) {
    var re = new RegExp(source, "g");
    var out = "";
    var at = 0;
    var m;
    while ((m = re.exec(text)) !== null) {
      var cls = "";
      for (var i = 1; i < m.length; i++) {
        if (m[i] !== undefined) {
          cls = classes[i];
          break;
        }
      }
      // A variable inside quotes is still read: its value is written into the text.
      var inner = cls === "str" ? paint(m[0], TEXT, TEXT_CLASSES) : Kit.esc(m[0]);
      out += Kit.esc(text.slice(at, m.index)) + (cls ? '<span class="kit-hl-' + cls + '">' + inner + "</span>" : inner);
      at = re.lastIndex;
    }
    return out + Kit.esc(text.slice(at));
  }

  function highlight(text, mode, escapes) {
    text = Kit.str(text);
    var out = evaluated(mode) ? paint(text, CODE, CODE_CLASSES) : paint(text, escapes ? ESCAPED : TEXT, TEXT_CLASSES);
    // A last empty line needs something in it, or the <pre> ends a line short of the textarea.
    if (out === "" || text.charAt(text.length - 1) === "\n") out += "​";
    return out;
  }

  // ─── Plain-language errors ────────────────────────────────────────────────

  var KINDS = { number: "a number", string: "text", boolean: "true or false", nil: "nothing", table: "a table", "function": "a function" };
  function kind(name) {
    return KINDS[name] || name;
  }

  // A device as the rendered text names it, for the first token reading it.
  function refLabel(device, text, rendered) {
    var tokens = Kit.str(text).match(/PARAM\s*\{[^}]*\}/g) || [];
    var labels = Kit.str(rendered).match(/\[[^\[\]]* > [^\[\]]*\]/g) || [];
    if (tokens.length !== labels.length) return "";
    for (var i = 0; i < tokens.length; i++) {
      var m = /\{\s*([^,}]*?)\s*,/.exec(tokens[i]);
      if (m && m[1] === device) return labels[i].slice(1, labels[i].lastIndexOf(" > "));
    }
    return "";
  }

  function compileSentence(body) {
    var m = /^([\s\S]*?) near '?([\s\S]*?)'?$/.exec(body);
    if (!m) return body;
    var what = m[1];
    var near = m[2];
    var expected = /^'(.+?)' expected/.exec(what);
    if (near === "<eof>") {
      if (/^unfinished string/.test(what)) return "It stops before it's finished: a closing quote is missing.";
      if (expected) return "It stops before it's finished: " + expected[1] + " is missing.";
      return "It stops before it's finished: something should follow the last part.";
    }
    if (expected && expected[1] === "<eof>") {
      if (near === "=") return "Use == to compare, not =.";
      if (near === "!") return "Use ~= for not equal, not !=.";
      return "It reads as finished before " + near + ": that part is extra, or something before it is missing.";
    }
    if (expected) return expected[1] + " is missing near " + near + ".";
    if (/^unexpected symbol/.test(what)) return "Something is out of place near " + near + ".";
    if (/^malformed number/.test(what)) return near + " isn't a number.";
    if (/^unfinished string/.test(what)) return "A closing quote is missing near " + near + ".";
    return "Something is wrong near " + near + ": " + what + ".";
  }

  function runtimeSentence(body) {
    var m = /attempt to compare (\w+) with (\w+)/.exec(body);
    if (m) {
      var kinds = [m[1], m[2]].sort();
      if (kinds.indexOf("nil") >= 0) {
        return "This compares " + kind(kinds[0] === "nil" ? kinds[1] : kinds[0]) + " with something that has no value. A name may be misspelled, or text may need quotes.";
      }
      return "This can't compare " + kind(kinds[0]) + " with " + kind(kinds[1]) + ". Both sides of < or > have to be the same kind.";
    }
    if (/attempt to compare two /.test(body)) return "< and > only work on numbers or text.";
    m = /bad argument #\d+ to '(.+?)' \((\w+) expected, got (.+?)\)/.exec(body);
    if (m) return m[1] + " needs " + kind(m[2]) + " there, and this gives it " + kind(m[3]) + ".";
    // The sandbox's own limits, already in words.
    if (/^(?:the expression |a pattern |expressions can't )/.test(body)) return body.charAt(0).toUpperCase() + body.slice(1) + ".";
    m = /attempt to (perform arithmetic on|concatenate|call|index) (?:\w+ '(.+?)' )?\(?a (\w+) value\)?/.exec(body);
    if (!m) return body;
    var action = m[1];
    var name = m[2] === "?" ? "" : m[2];
    var what = m[3];
    var nil = what === "nil";
    if (action === "call") {
      if (nil) return name ? "There's no function named " + name + "." : "This calls a function that doesn't exist.";
      return name ? name + " isn't a function." : "This calls " + kind(what) + ", which isn't a function.";
    }
    if (action === "index") {
      if (nil) return name ? "There's nothing named " + name + " to read from." : "This reads from something that isn't there.";
      return "This reads a part of " + kind(what) + ", which has no parts.";
    }
    if (action === "concatenate") {
      if (nil && name) return "There's no value named " + name + " to join with text.";
      return "Only text and numbers can be joined, and this has " + kind(what) + ".";
    }
    if (nil && name) return "There's no value named " + name + ", so it can't be used in math.";
    if (what === "string") return "This does math on text: a value here isn't a number.";
    return "This does math on " + kind(what) + ".";
  }

  // text and rendered give a device's name to a reason that has only its id; label names the field.
  function expressionError(raw, text, rendered, label) {
    var error = Kit.str(raw);
    var field = label ? '"' + label + '"' : "It";
    var m = /^result is not a (boolean|number) \(got (\w+)\)$/.exec(error);
    if (m) {
      if (m[1] === "boolean") return field + " has to come out true or false: add a comparison.";
      return field + " has to come out a number, and this gives " + kind(m[2]) + ".";
    }
    m = /^variable ([\s\S]+) not found on device ([\s\S]+)$/.exec(error);
    if (m) {
      return (refLabel(m[2], text, rendered) || "Device " + m[2]) + " has no variable " + (/^\d+$/.test(m[1]) ? "" : "named ") + m[1] + ".";
    }
    m = /^device ([\s\S]+) not found$/.exec(error);
    if (m) return "There's no device " + m[1] + " in this project.";
    m = /^device ([\s\S]+) was removed from the project$/.exec(error);
    if (m) return (refLabel(m[1], text, rendered) || "Device " + m[1]) + " was removed from the project.";
    m = /^(compile|runtime) error: (?:[\s\S]*"\]:\d+: )?([\s\S]*)$/.exec(error);
    if (!m) return error;
    return (m[1] === "compile" ? compileSentence : runtimeSentence)(m[2]).replace(/__p(\[\d+\])?/g, "a variable");
  }

  // ─── Help ─────────────────────────────────────────────────────────────────

  function code(list) {
    return list
      .map(function (text) {
        return "<code>" + Kit.esc(text) + "</code>";
      })
      .join(" ");
  }

  var HELP = {
    tokens: {
      title: "Variables",
      html:
        "<p><code>PARAM{device id,variable id}</code> reads a variable's current value. Choosing a variable from the list puts one at the cursor.</p>" +
        "<p>A variable can also go by its exact name, case and all: <code>PARAM{device id,LEVEL}</code>.</p>",
    },
    condition: {
      title: "True or false",
      html: "<p>It has to come out <code>true</code> or <code>false</code>, so it usually ends in a comparison. A variable that already holds true or false can stand alone.</p>",
    },
    equation: {
      title: "A number",
      html:
        "<p>It is worked out as math with each variable's value, and has to come out a number.</p>" +
        "<p>A comparison picks between two numbers: <code>PARAM{device id,variable id} &gt; 50 and 1 or 0</code>.</p>",
    },
    operators: {
      title: "Comparing",
      html:
        "<p>" + code(["==", "~=", "<", "<=", ">", ">="]) + ", where <code>~=</code> means not equal.</p>" +
        "<p>Join them with " + code(["and", "or", "not"]) + ".</p>" +
        "<p>Math: " + code(["+", "-", "*", "/", "%", "^", "( )"]) + ", and <code>..</code> joins text.</p>",
    },
    text: {
      title: "Text",
      html:
        '<p>Put text in double quotes: <code>== "Charging"</code>. It matches exactly, case and all.</p>' +
        "<p>A value that is a number or true or false compares as one. Any other value compares as text.</p>",
    },
    functions: {
      title: "Functions",
      html:
        "<p>" + code(["abs", "ceil", "floor", "sqrt", "min", "max", "round(x, places)", "pi", "huge"]) + "</p>" +
        "<p>" + code(["c2f", "f2c"]) + " convert between Celsius and Fahrenheit.</p>" +
        "<p>" + code(["device_name(id)", "room_name(id)"]) + " give a device's name and room.</p>" +
        '<p><code>json(text, "$.path")</code> reads one value from JSON text: <code>json(PARAM{device id,variable id}, "$.sensors[0].temp")</code>. ' +
          "Fields follow dots, <code>[0]</code> is an array's first item, and <code>[0][1]</code> reads an array inside one. An object or array comes back as its JSON text, and text that isn't JSON or a path to nothing gives nil.</p>" +
        "<p>" + code(["tonumber", "tostring", "type"]) + ", and the <code>math</code> and <code>string</code> libraries: <code>math.fmod</code>, <code>string.lower</code> and the rest.</p>",
    },
    string: {
      title: "Text with variables",
      html: "<p>The text as written, with each variable's current value in place of its <code>PARAM{device id,variable id}</code>. Nothing in it is worked out.</p>",
    },
    escapes: {
      title: "Escapes",
      html:
        "<p>" + code(["\\r", "\\n", "\\t", "\\0", "\\\\"]) + " stand for a carriage return, a line feed, a tab, a zero byte and a backslash.</p>" +
        "<p><code>\\xNN</code> stands for the byte with those two hex digits.</p>",
    },
  };

  var HELP_FOR = {
    condition: ["condition", "tokens", "operators", "text", "functions"],
    equation: ["tokens", "equation", "operators", "text", "functions"],
    string: ["tokens", "string"],
    text: ["tokens"],
  };

  function helpSections(mode, escapes) {
    var list = (HELP_FOR[mode] || HELP_FOR.equation).slice();
    if (escapes && !evaluated(mode)) list.push("escapes");
    return list;
  }

  // A help panel: options { toggle, panel, wrap, sections, mode, escapes }. Returns { open(state), isOpen(), render(mode) }.
  function expressionHelp(options) {
    var toggle = options.toggle;
    var panel = options.panel;
    var shown = options.wrap || panel;
    var open = false;
    panel.classList.add("kit-help");

    function render(mode) {
      var list = options.sections || helpSections(mode || options.mode, options.escapes);
      panel.innerHTML = list
        .map(function (item) {
          var section = typeof item === "string" ? HELP[item] : item;
          return section ? "<section><h4>" + Kit.esc(section.title) + "</h4>" + section.html + "</section>" : "";
        })
        .join("");
    }

    function show(state) {
      open = !!state;
      shown.hidden = !open;
      if (toggle) {
        toggle.textContent = open ? "Hide syntax help" : "Syntax help";
        toggle.setAttribute("aria-expanded", String(open));
      }
    }

    if (toggle) {
      toggle.classList.add("kit-help-toggle");
      // A button's own type submits a form it sits in.
      if (!toggle.getAttribute("type")) toggle.setAttribute("type", "button");
      toggle.addEventListener("click", function () {
        show(!open);
      });
    }
    render(options.mode);
    show(false);
    return {
      open: show,
      isOpen: function () {
        return open;
      },
      render: render,
    };
  }

  // ─── The editor ───────────────────────────────────────────────────────────

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text) node.textContent = text;
    return node;
  }

  // The preview's own block, ahead of what the page put in the element: a page's line under it stays.
  function previewParts(box) {
    box.classList.add("kit-prev");
    var parts = { body: el("div", "kit-prev-body") };
    parts.body.appendChild(el("div", "kit-prev-label", "References"));
    parts.body.appendChild((parts.rendered = el("div", "kit-prev-value")));
    parts.sub = el("div");
    parts.sub.appendChild(el("div", "kit-prev-label", "With current values"));
    parts.sub.appendChild((parts.substituted = el("div", "kit-prev-value")));
    parts.body.appendChild(parts.sub);
    parts.res = el("div");
    parts.res.appendChild(el("div", "kit-prev-label", "Result"));
    parts.res.appendChild((parts.result = el("div", "kit-prev-result")));
    parts.res.appendChild((parts.error = el("div", "kit-prev-error")));
    parts.body.appendChild(parts.res);
    box.insertBefore(parts.body, box.firstChild);
    return parts;
  }

  var editors = {};
  var made = 0;

  // Each editor's answers come back under its own id prefix, so several editors share one command.
  Kit.listen("EVAL_RESULT", function (result) {
    var id = Kit.str(result && result.id);
    var answer = editors[id.slice(0, id.lastIndexOf("-") + 1)];
    if (answer) answer(result);
  });

  function expressionEditor(textarea, options) {
    options = options || {};
    var mode = options.mode || "equation";
    var minHeight = options.singleLine ? 32 : 64;
    var prefix = "x" + ++made + "-";
    var seq = 0;
    var timer = null;

    var box = el("div", "kit-editor" + (options.singleLine ? " kit-editor-line" : ""));
    var pre = el("pre", "kit-editor-hl");
    pre.setAttribute("aria-hidden", "true");
    textarea.parentNode.insertBefore(box, textarea);
    box.appendChild(pre);
    box.appendChild(textarea);
    textarea.setAttribute("spellcheck", "false");

    var parts = options.preview ? previewParts(options.preview) : null;
    var help = options.help && options.help.panel ? expressionHelp({
      toggle: options.help.toggle,
      panel: options.help.panel,
      wrap: options.help.wrap,
      sections: options.help.sections,
      mode: mode,
      escapes: options.escapes,
    }) : null;

    function value() {
      return options.singleLine ? textarea.value.replace(/\s*\n\s*/g, " ") : textarea.value;
    }

    // Grown to fit, so the two layers never scroll apart.
    function sync() {
      pre.innerHTML = highlight(textarea.value, mode, options.escapes);
      textarea.style.height = "auto";
      textarea.style.height = Math.max(minHeight, textarea.scrollHeight) + "px";
    }

    function used() {
      var found = {};
      var re = new RegExp(USED.source, "g");
      var m;
      while ((m = re.exec(textarea.value)) !== null) found[m[1] + ":" + m[2]] = true;
      return found;
    }

    function countWatched() {
      if (!options.watch) return;
      var n = Object.keys(used()).length;
      options.watch.hidden = !n;
      options.watch.textContent = n ? "Watching " + n + " reference" + (n === 1 ? "" : "s") : "";
    }

    function idle() {
      textarea.classList.remove("input-error");
      if (!parts) return;
      parts.rendered.textContent = "Preview appears as you type.";
      parts.sub.hidden = true;
      parts.res.hidden = true;
    }

    function ask() {
      Kit.sendCommand("_EVAL_EXPRESSION", { id: prefix + seq, mode: mode, expression: value().trim() });
    }

    // Each change makes a new id, so an answer to earlier text is dropped.
    function schedule(now) {
      clearTimeout(timer);
      seq++;
      var text = value();
      var wanted = mode !== "text" && !!(parts || options.onResult) && (options.previewWhen ? options.previewWhen(text) : text.trim() !== "");
      if (!wanted) return idle();
      if (now) ask();
      else timer = setTimeout(ask, 350);
    }

    function changed(byUser) {
      sync();
      countWatched();
      editor.hold = "";
      schedule(false);
      // After the kit's reset, so what the page marks on the field stays.
      if (byUser && options.onInput) options.onInput(value());
    }

    function show(result) {
      var error = Kit.str(result.error);
      parts.rendered.textContent = Kit.str(result.rendered);
      parts.substituted.textContent = Kit.str(result.substituted).replace(/ERROR_VARIABLE_NOT_FOUND/g, "(not found)");
      parts.sub.hidden = mode === "string" || !!result.hold;
      parts.res.hidden = false;
      parts.result.hidden = !!error;
      parts.error.hidden = !error;
      parts.error.textContent = result.message;
      parts.error.title = error;
      if (error) return;
      var text = Kit.str(result.result);
      if (mode === "condition") {
        var yes = text === "true";
        parts.result.textContent = yes ? "True" : "False";
        parts.result.className = "kit-prev-result " + (yes ? "true" : "false");
      } else {
        parts.result.textContent = text;
        parts.result.className = "kit-prev-result";
      }
    }

    editors[prefix] = function (result) {
      if (Kit.str(result.id) !== prefix + seq) return;
      var error = Kit.str(result.error);
      result.message = error ? expressionError(error, value(), result.rendered, options.label) : "";
      editor.hold = result.hold ? result.message : "";
      textarea.classList.toggle("input-error", !!error);
      if (parts) show(result);
      if (options.onResult) options.onResult(result, editor);
    };

    textarea.addEventListener("input", function () {
      changed(true);
    });
    if (options.singleLine) {
      textarea.addEventListener("keydown", function (e) {
        if (e.key === "Enter") e.preventDefault();
      });
    }
    // A narrower pane wraps the text onto more lines, and a field shown late had no width to measure.
    if (window.ResizeObserver) {
      var width = 0;
      new window.ResizeObserver(function () {
        var now = textarea.clientWidth;
        if (now && now !== width) {
          width = now;
          sync();
        }
      }).observe(textarea);
    }

    var editor = {
      hold: "",
      textarea: textarea,
      value: value,
      setValue: function (text) {
        textarea.value = Kit.str(text);
        changed(false);
      },
      setMode: function (next) {
        mode = next;
        if (help) help.render(mode);
        changed(false);
      },
      // At the cursor, in place of what is selected, as an edit of the integrator's own.
      insert: function (text) {
        var at = typeof textarea.selectionStart === "number" ? textarea.selectionStart : textarea.value.length;
        var end = typeof textarea.selectionEnd === "number" ? textarea.selectionEnd : at;
        textarea.value = textarea.value.slice(0, at) + text + textarea.value.slice(end);
        textarea.focus();
        textarea.setSelectionRange(at + text.length, at + text.length);
        changed(true);
      },
      sync: sync,
      preview: function (now) {
        schedule(!!now);
      },
      used: used,
      help: help,
    };

    sync();
    countWatched();
    idle();
    return editor;
  }

  Kit.expressionEditor = expressionEditor;
  Kit.expressionHelp = expressionHelp;
  Kit.expressionError = expressionError;
})();
