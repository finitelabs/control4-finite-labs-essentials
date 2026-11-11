// Groups that fold under a caret, for a page that draws its markup as strings and draws it again on every push: each
// set keeps its groups' open state by key, a click on a head turns it, and Expand all / Collapse all follows what is
// on screen. A page embeds it after page.js, and collapse.css after style.css, the same way.
//   Kit.collapse(name, options)   a set of groups; options.open is the default state (true), options.onChange() draws
//                                 the page again after a click
//     set.isOpen(key)             a group's state: its own once clicked, else the set's default
//     set.anyOpen(keys)           whether any of these groups is open
//     set.head(key)               the attributes for the page's own head element, which also takes kit-collapse-head
//     set.group(key, head, body, bodyClass)  a group: its head's markup, then its body, shown while it is open
//     set.toggleAll(keys)         the Expand all / Collapse all button for these groups, or "" when there are none
//     set.toggle(key), set.setAll(open)
//   Kit.collapse.caret(none)      the caret a head shows; none keeps its place on a row with nothing to open

(function (Kit) {
  var sets = {};

  function collapse(name, options) {
    options = options || {};
    var own = {};
    var all = options.open !== false;

    function isOpen(key) {
      return Object.prototype.hasOwnProperty.call(own, key) ? own[key] : all;
    }

    var set = {
      onChange: options.onChange || function () {},
      isOpen: isOpen,
      anyOpen: function (keys) {
        return keys.some(isOpen);
      },
      toggle: function (key) {
        own[key] = !isOpen(key);
      },
      // Every group follows the new default, so a group opened by hand closes with the rest.
      setAll: function (open) {
        own = {};
        all = !!open;
      },
      head: function (key) {
        return 'data-kit-collapse="' + Kit.esc(name) + '" data-key="' + Kit.esc(key) + '"';
      },
      group: function (key, head, body, bodyClass) {
        return (
          '<div class="kit-collapse' + (isOpen(key) ? " open" : "") + '">' + head +
          '<div class="kit-collapse-body' + (bodyClass ? " " + bodyClass : "") + '">' + body + "</div></div>"
        );
      },
      // It offers what a click would do to what is on screen: with any group open, Collapse all.
      toggleAll: function (keys) {
        if (!keys.length) return "";
        var open = set.anyOpen(keys);
        return (
          '<button type="button" class="kit-collapse-all" data-kit-collapse-all="' + Kit.esc(name) + '" data-open="' +
          !open + '">' + (open ? "Collapse all" : "Expand all") + "</button>"
        );
      },
    };
    sets[name] = set;
    return set;
  }

  collapse.caret = function (none) {
    return '<span class="kit-caret' + (none ? ' none">' : '">▸') + "</span>";
  };

  document.addEventListener("click", function (e) {
    var t = e.target;
    if (!t || !t.closest) return;
    var all = t.closest("[data-kit-collapse-all]");
    var head = all ? null : t.closest("[data-kit-collapse]");
    var set = all ? sets[all.getAttribute("data-kit-collapse-all")] : head ? sets[head.getAttribute("data-kit-collapse")] : null;
    if (!set) return;
    if (all) set.setAll(all.getAttribute("data-open") === "true");
    else set.toggle(head.getAttribute("data-key"));
    set.onChange();
  });

  Kit.collapse = collapse;
})(Kit);
