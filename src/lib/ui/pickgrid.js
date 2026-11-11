// Picking a picture: a grid of picture cells to pick one from, and a zone a file is dropped on, chosen into or pasted
// into. A page embeds it after page.js, with pickgrid.css after style.css.
//   Kit.pickGrid(el, options)   el becomes the grid; returns { fill(items, empty), set(item), mark(id), cell(id) }:
//                               set redraws one item's cell in place, and the picked id's cell stays marked
//     onPick(id)                a cell was picked
//     empty                     what an empty grid says, unless fill names it
//   An item is { id, title, src } for a picture or { id, title, text } for words in its place, with dark (a picture
//   drawn on a dark tile), photo (one that fills the cell) and tag (a word in its corner).
//   Kit.dropZone(el, options)   el becomes the zone
//     onFile(file)              a file was dropped, chosen or pasted
//     choose                    the button that opens the file chooser
//     accept                    the chooser's accepted types
//     pasteWhen()               whether a picture pasted outside a text box goes to this zone now

(function (Kit) {
  function cellFor(item) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "kit-pick" + (item.dark ? " dark" : "") + (item.photo ? " photo" : "");
    b.dataset.id = item.id;
    b.title = item.title || item.id;
    if (item.src) {
      var img = document.createElement("img");
      img.alt = "";
      img.src = item.src;
      b.appendChild(img);
    } else {
      var t = document.createElement("span");
      t.className = "kit-pick-text";
      t.textContent = item.text || item.id;
      b.appendChild(t);
    }
    if (item.tag) {
      var tag = document.createElement("span");
      tag.className = "kit-pick-tag";
      tag.textContent = item.tag;
      b.appendChild(tag);
    }
    return b;
  }

  function pickGrid(el, options) {
    options = options || {};
    var picked = null;
    el.classList.add("kit-pickgrid");
    function find(id) {
      return el.querySelector('button[data-id="' + String(id).replace(/["\\]/g, "\\$&") + '"]');
    }
    el.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-id]");
      if (b && el.contains(b) && options.onPick) options.onPick(b.dataset.id);
    });
    function mark(id) {
      picked = id == null ? null : String(id);
      Array.prototype.forEach.call(el.querySelectorAll("button[data-id]"), function (b) {
        b.classList.toggle("on", b.dataset.id === picked);
      });
    }
    return {
      fill: function (items, empty) {
        el.textContent = "";
        if (!items.length) {
          var d = document.createElement("div");
          d.className = "empty";
          d.textContent = empty || options.empty || "Nothing here.";
          el.appendChild(d);
          return;
        }
        var frag = document.createDocumentFragment();
        items.forEach(function (item) {
          frag.appendChild(cellFor(item));
        });
        el.appendChild(frag);
        mark(picked);
      },
      set: function (item) {
        var old = find(item.id);
        if (!old) return;
        var cell = cellFor(item);
        cell.classList.toggle("on", cell.dataset.id === picked);
        el.insertBefore(cell, old);
        el.removeChild(old);
      },
      mark: mark,
      cell: find,
    };
  }

  function dropZone(el, options) {
    options = options || {};
    el.classList.add("kit-drop");
    var file = document.createElement("input");
    file.type = "file";
    file.hidden = true;
    if (options.accept) file.accept = options.accept;
    el.appendChild(file);
    file.addEventListener("change", function () {
      var f = file.files && file.files[0];
      file.value = "";
      if (f) options.onFile(f);
    });
    if (options.choose) {
      options.choose.addEventListener("click", function () {
        file.click();
      });
    }
    ["dragenter", "dragover"].forEach(function (t) {
      el.addEventListener(t, function (e) {
        e.preventDefault();
        el.classList.add("over");
      });
    });
    ["dragleave", "drop"].forEach(function (t) {
      el.addEventListener(t, function () {
        el.classList.remove("over");
      });
    });
    el.addEventListener("drop", function (e) {
      e.preventDefault();
      var f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
      if (f) options.onFile(f);
    });
    if (options.pasteWhen) {
      document.addEventListener("paste", function (e) {
        if (!options.pasteWhen() || /^(INPUT|TEXTAREA)$/.test((e.target && e.target.tagName) || "")) return;
        var item = Array.prototype.find.call((e.clipboardData && e.clipboardData.items) || [], function (i) {
          return i.kind === "file" && /^image\//.test(i.type);
        });
        if (!item) return;
        e.preventDefault();
        options.onFile(item.getAsFile());
      });
    }
  }

  Kit.pickGrid = pickGrid;
  Kit.dropZone = dropZone;
})(Kit);
