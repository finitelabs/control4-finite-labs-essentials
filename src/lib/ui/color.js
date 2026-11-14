// The color picker, in place of the browser's own: Composer embeds Edge, whose picker's dropper reads the wrong place
// in Composer's window. Each color input gets a swatch button that opens a popover with the colors a page offers, the
// recent ones, a hex box, hue, saturation and lightness sliders and, given a picture, a dropper with a loupe. A page
// embeds it after page.js, with color.css after style.css.
//   Kit.color                          normal(text) to #RRGGBB or null; rgb(hex), hex([r, g, b]), hsl(hex) to
//                                      { h, s, l } and fromHsl({ h, s, l })
//   Kit.colorPicker(input, options)    takes over an <input type="color">; Kit.colorPicker.close(keep) closes the
//                                      open one, keeping its color or, with keep false, undoing it as Esc does
//     offer()          rows shown first, [{ title, colors }], each color a hex
//     recentKey        the localStorage key the recent colors are kept under; "kitRecentColors" by default
//     dropper          { when(): whether to offer it, image(): the <img> it reads, area(): what that sits in,
//                      backdrop(): [r, g, b] under the image's see-through pixels }
//     onOpen(), onCancel(start)  told as it opens, and on Esc instead of putting the input back to start
// The input keeps the value: setting it from code repaints the swatch, a pick sets it and fires its input event, and
// a no-color class on it crosses the swatch out.

(function (Kit) {
  var VALUE = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
  var LOUPE_CELLS = 11;
  var LOUPE_ZOOM = 9;
  var DROPPER_ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"' +
    ' stroke-linejoin="round" aria-hidden="true"><path d="M13 8l3 3-8 8H5v-3z"/><path d="M12 5l7 7"/>' +
    '<path d="M15 6l2.2-2.2a2.3 2.3 0 0 1 3.3 3.3L18.3 9"/></svg>';

  function normal(v) {
    var m = /^#?([0-9a-f]{6}|[0-9a-f]{3})$/i.exec(String(v == null ? "" : v).trim());
    if (!m) return null;
    var h = m[1].length === 3 ? m[1].replace(/./g, "$&$&") : m[1];
    return "#" + h.toUpperCase();
  }
  function rgb(h) {
    return [1, 3, 5].map(function (i) {
      return parseInt(h.slice(i, i + 2), 16);
    });
  }
  function hex(c) {
    return (
      "#" +
      c
        .map(function (v) {
          return Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0");
        })
        .join("")
        .toUpperCase()
    );
  }
  function hsl(h) {
    var c = rgb(h).map(function (v) {
      return v / 255;
    });
    var mx = Math.max.apply(0, c), mn = Math.min.apply(0, c);
    var l = (mx + mn) / 2, d = mx - mn, s = 0, hue = 0;
    if (d) {
      s = d / (1 - Math.abs(2 * l - 1));
      hue = mx === c[0] ? ((c[1] - c[2]) / d) % 6 : mx === c[1] ? (c[2] - c[0]) / d + 2 : (c[0] - c[1]) / d + 4;
      hue *= 60;
      if (hue < 0) hue += 360;
    }
    return { h: hue, s: Math.min(1, s), l: l };
  }
  function fromHsl(o) {
    var c = (1 - Math.abs(2 * o.l - 1)) * o.s, x = c * (1 - Math.abs(((o.h / 60) % 2) - 1)), m = o.l - c / 2;
    var r = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]][Math.floor(o.h / 60) % 6];
    return hex(
      r.map(function (v) {
        return (v + m) * 255;
      })
    );
  }
  Kit.color = { normal: normal, rgb: rgb, hex: hex, hsl: hsl, fromHsl: fromHsl };

  function recent(key) {
    try {
      return (JSON.parse(localStorage.getItem(key)) || []).map(normal).filter(Boolean).slice(0, 10);
    } catch (e) {
      return [];
    }
  }
  function remember(key, h) {
    var list = [h].concat(
      recent(key).filter(function (c) {
        return c !== h;
      })
    );
    try {
      localStorage.setItem(key, JSON.stringify(list.slice(0, 10)));
    } catch (e) {}
  }

  function paint(input) {
    var btn = input.kitSwatch;
    if (!btn) return;
    btn.firstChild.style.background = VALUE.get.call(input);
    btn.classList.toggle("no-color", input.classList.contains("no-color"));
  }
  // Set as a person picking would, so the page's own handler runs.
  function pick(input, h) {
    if (VALUE.get.call(input).toUpperCase() === h) return;
    VALUE.set.call(input, h.toLowerCase());
    paint(input);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  }

  // The picture's pixel under the pointer, kept inside it where a scaled edge falls between pixels.
  function pixelAt(img, e) {
    var r = img.getBoundingClientRect();
    if (!img.naturalWidth || !r.width || !r.height) return null;
    var at = function (v, from, size, n) {
      return Math.max(0, Math.min(n - 1, Math.floor(((v - from) / size) * n)));
    };
    return { x: at(e.clientX, r.left, r.width, img.naturalWidth), y: at(e.clientY, r.top, r.height, img.naturalHeight) };
  }
  function canvasOf(img) {
    if (!img.kitPixels) {
      var c = document.createElement("canvas");
      c.width = img.naturalWidth;
      c.height = img.naturalHeight;
      c.getContext("2d", { willReadFrequently: true }).drawImage(img, 0, 0);
      img.kitPixels = c;
    }
    return img.kitPixels;
  }
  function colorAt(img, p, back) {
    var d = canvasOf(img).getContext("2d").getImageData(p.x, p.y, 1, 1).data, a = d[3] / 255;
    return hex(
      back.map(function (v, i) {
        return d[i] * a + v * (1 - a);
      })
    );
  }
  // The pixels around the pointer, magnified, beside it and inside the window.
  function drawLoupe(loupe, img, p, e, h, back) {
    var n = LOUPE_CELLS, z = LOUPE_ZOOM, half = (n - 1) / 2, ctx = loupe.firstChild.getContext("2d");
    ctx.imageSmoothingEnabled = false;
    ctx.fillStyle = hex(back);
    ctx.fillRect(0, 0, n * z, n * z);
    ctx.drawImage(canvasOf(img), p.x - half, p.y - half, n, n, 0, 0, n * z, n * z);
    ctx.strokeStyle = "#000000";
    ctx.strokeRect(half * z - 0.5, half * z - 0.5, z + 1, z + 1);
    ctx.strokeStyle = "#FFFFFF";
    ctx.strokeRect(half * z + 0.5, half * z + 0.5, z - 1, z - 1);
    loupe.lastChild.textContent = h;
    loupe.hidden = false;
    var w = loupe.offsetWidth, ht = loupe.offsetHeight, gap = 18, page = document.documentElement;
    loupe.style.left = (e.clientX + gap + w > page.clientWidth ? e.clientX - gap - w : e.clientX + gap) + "px";
    loupe.style.top = (e.clientY + gap + ht > page.clientHeight ? e.clientY - gap - ht : e.clientY + gap) + "px";
  }

  var current = null;

  function close(keep) {
    var pop = current;
    if (!pop) return;
    current = null;
    pop.stopDropping();
    pop.remove();
    document.removeEventListener("mousedown", pop.outside, true);
    document.removeEventListener("keydown", pop.keys, true);
    var input = pop.input, o = input.kitColor;
    if (keep !== false) {
      var now = VALUE.get.call(input).toUpperCase();
      if (now !== pop.start) remember(o.recentKey || "kitRecentColors", now);
    } else if (o.onCancel) {
      o.onCancel(pop.start);
    } else {
      pick(input, pop.start);
    }
    input.kitSwatch.focus();
  }

  function open(input) {
    close(true);
    var o = input.kitColor, key = o.recentKey || "kitRecentColors", dropper = o.dropper;
    var start = VALUE.get.call(input).toUpperCase();
    if (o.onOpen) o.onOpen();
    var pop = document.createElement("div");
    pop.className = "kit-pop kit-color";
    pop.setAttribute("role", "dialog");
    pop.setAttribute("aria-label", "Choose a color");
    pop.input = input;
    pop.start = start;
    var rows = (o.offer ? o.offer() : []).concat([{ title: "Recent", colors: recent(key) }]);
    pop.innerHTML =
      rows
        .filter(function (r) {
          return r.colors && r.colors.length;
        })
        .map(function (r) {
          return (
            '<div class="kit-color-label">' + Kit.esc(r.title) + '</div><div class="kit-color-chips">' +
            r.colors
              .map(function (h) {
                return (
                  '<button type="button" class="kit-color-chip" data-hex="' + h + '" title="' + h + '" aria-label="' +
                  h + '" style="background:' + h + '"></button>'
                );
              })
              .join("") +
            "</div>"
          );
        })
        .join("") +
      '<div class="kit-color-hex"><span></span><input type="text" class="sm" maxlength="7" spellcheck="false"' +
      ' aria-label="Hex color"><button type="button" class="kit-color-dropper" aria-pressed="false"' +
      ' title="Pick a color from the picture" aria-label="Pick a color from the picture">' + DROPPER_ICON +
      '</button></div><div class="kit-color-hint" hidden>Click the picture to pick a color.</div>' +
      ["H", "S", "L"]
        .map(function (k) {
          return (
            '<label class="kit-color-slider"><span>' + k + '</span><input type="range" data-k="' + k +
            '" min="0" max="' + (k === "H" ? 359 : 100) + '" aria-label="' +
            { H: "Hue", S: "Saturation", L: "Lightness" }[k] + '"><code></code></label>'
          );
        })
        .join("");
    var box = pop.querySelector(".kit-color-hex input"), sample = pop.querySelector(".kit-color-hex span");
    var sliders = pop.querySelectorAll(".kit-color-slider input"), drop = pop.querySelector(".kit-color-dropper");
    var hint = pop.querySelector(".kit-color-hint"), loupe = null, tone = hsl(start);
    var now = function () {
      return VALUE.get.call(input).toUpperCase();
    };
    var show = function (h, from) {
      sample.style.background = h;
      if (from !== "hex") {
        box.value = h;
        box.classList.remove("input-error");
      }
      if (from !== "slider") tone = hsl(h);
      var v = { H: Math.round(tone.h), S: Math.round(tone.s * 100), L: Math.round(tone.l * 100) };
      Array.prototype.forEach.call(sliders, function (r) {
        if (from !== "slider") r.value = v[r.dataset.k];
        r.nextElementSibling.textContent = v[r.dataset.k] + (r.dataset.k === "H" ? "" : "%");
      });
      sliders[0].style.background =
        "linear-gradient(to right," +
        [0, 60, 120, 180, 240, 300, 359]
          .map(function (d) {
            return "hsl(" + d + ",100%,50%)";
          })
          .join(",") +
        ")";
      sliders[1].style.background =
        "linear-gradient(to right,hsl(" + v.H + ",0%," + v.L + "%),hsl(" + v.H + ",100%," + v.L + "%))";
      sliders[2].style.background = "linear-gradient(to right,#000,hsl(" + v.H + "," + v.S + "%,50%),#fff)";
      Array.prototype.forEach.call(pop.querySelectorAll(".kit-color-chip"), function (c) {
        c.classList.toggle("on", c.dataset.hex === h);
      });
    };
    pop.addEventListener("click", function (e) {
      var chip = e.target.closest(".kit-color-chip");
      if (!chip) return;
      pick(input, chip.dataset.hex);
      show(chip.dataset.hex);
    });
    box.addEventListener("input", function () {
      var h = normal(box.value);
      box.classList.toggle("input-error", !h);
      if (h) {
        pick(input, h);
        show(h, "hex");
      }
    });
    box.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        e.preventDefault();
        close(true);
      }
    });
    Array.prototype.forEach.call(sliders, function (r) {
      r.addEventListener("input", function () {
        tone = { h: Number(sliders[0].value), s: Number(sliders[1].value) / 100, l: Number(sliders[2].value) / 100 };
        var h = normal(fromHsl(tone));
        pick(input, h);
        show(h, "slider");
      });
    });

    // The dropper: armed by its button, it shows the color under the pointer and picks it on a click.
    drop.hidden = !(dropper && (dropper.when ? dropper.when() : dropper.image()));
    var back = function () {
      return dropper.backdrop ? dropper.backdrop() : [255, 255, 255];
    };
    var area = function () {
      return dropper.area ? dropper.area() : dropper.image();
    };
    pop.stopDropping = function () {
      if (!pop.dropping) return;
      pop.dropping = false;
      drop.setAttribute("aria-pressed", "false");
      hint.hidden = true;
      var a = area();
      if (a) a.classList.remove("kit-color-target");
      document.removeEventListener("mousemove", pop.hover, true);
      document.removeEventListener("mouseout", pop.away, true);
      if (loupe) loupe.remove();
      loupe = null;
      sample.style.background = now();
    };
    pop.hover = function (e) {
      var img = dropper.image(), p = img && e.target === img && pixelAt(img, e);
      if (!p) {
        if (loupe) loupe.hidden = true;
        sample.style.background = now();
        return;
      }
      var h = colorAt(img, p, back());
      if (!loupe) {
        loupe = document.createElement("div");
        loupe.className = "kit-color-loupe";
        loupe.innerHTML =
          '<canvas width="' + LOUPE_CELLS * LOUPE_ZOOM + '" height="' + LOUPE_CELLS * LOUPE_ZOOM + '"></canvas><code></code>';
        document.body.appendChild(loupe);
      }
      drawLoupe(loupe, img, p, e, h, back());
      sample.style.background = h;
    };
    pop.away = function (e) {
      if (e.relatedTarget) return;
      if (loupe) loupe.hidden = true;
      sample.style.background = now();
    };
    drop.addEventListener("click", function () {
      if (pop.dropping) {
        pop.stopDropping();
        return;
      }
      pop.dropping = true;
      drop.setAttribute("aria-pressed", "true");
      hint.hidden = false;
      var a = area();
      if (a) a.classList.add("kit-color-target");
      document.addEventListener("mousemove", pop.hover, true);
      document.addEventListener("mouseout", pop.away, true);
      // Over the picture, as in a narrow window, the picker moves above its swatch.
      if (!a) return;
      var t = a.getBoundingClientRect(), b = pop.getBoundingClientRect(), at = input.kitSwatch.getBoundingClientRect();
      if (b.left < t.right && b.right > t.left && b.top < t.bottom && b.bottom > t.top && at.top - b.height - 6 >= 0) {
        pop.style.top = at.top - b.height - 6 + window.scrollY + "px";
      }
    });
    pop.outside = function (e) {
      if (pop.dropping && !drop.contains(e.target)) {
        var img = dropper.image(), p = e.button === 0 && img && e.target === img && pixelAt(img, e);
        var h = p && colorAt(img, p, back());
        pop.stopDropping();
        if (h) {
          // A pick, not a click away: the picker stays open on the new color.
          e.preventDefault();
          pick(input, h);
          show(h);
          return;
        }
        // A near miss on the picture's area only stops the dropper.
        var a = area();
        if (a && a.contains(e.target)) return;
      }
      if (!pop.contains(e.target) && !input.kitSwatch.contains(e.target)) close(true);
    };
    pop.keys = function (e) {
      if (e.key !== "Escape") return;
      e.preventDefault();
      if (pop.dropping) pop.stopDropping();
      else close(false);
    };
    document.addEventListener("mousedown", pop.outside, true);
    document.addEventListener("keydown", pop.keys, true);
    document.body.appendChild(pop);
    var at = input.kitSwatch.getBoundingClientRect();
    var left = Math.max(8, Math.min(at.left, document.documentElement.clientWidth - pop.offsetWidth - 8));
    pop.style.left = left + window.scrollX + "px";
    pop.style.top = at.bottom + 6 + window.scrollY + "px";
    current = pop;
    show(start);
    box.focus();
    box.select();
  }

  function colorPicker(input, options) {
    input.kitColor = options || {};
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "kit-swatch";
    btn.id = input.id + "-swatch";
    btn.appendChild(document.createElement("span"));
    var label = input.id && document.querySelector('label[for="' + input.id + '"]');
    if (label) {
      label.htmlFor = btn.id;
      btn.setAttribute("aria-label", label.textContent);
    }
    input.kitSwatch = btn;
    input.hidden = true;
    input.tabIndex = -1;
    input.parentNode.insertBefore(btn, input);
    // The page also sets the value from code, and the swatch follows.
    Object.defineProperty(input, "value", {
      configurable: true,
      get: function () {
        return VALUE.get.call(this);
      },
      set: function (v) {
        VALUE.set.call(this, v);
        paint(this);
      },
    });
    new MutationObserver(function () {
      paint(input);
    }).observe(input, { attributes: true, attributeFilter: ["class"] });
    btn.addEventListener("click", function () {
      if (current && current.input === input) close(true);
      else open(input);
    });
    paint(input);
  }
  colorPicker.close = close;

  Kit.colorPicker = colorPicker;
})(Kit);
