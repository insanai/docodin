/*
 * docodin theme: colour theme toggle, search (dropdown and search page),
 * "On this page" highlighting, copy buttons and keyboard shortcuts for the
 * native HTML site built by `docodin book build`.  No dependencies.
 */
(function () {
  "use strict";

  var root = document.documentElement;
  var base = (document.body && document.body.getAttribute("data-root")) || "";

  /* --- colour theme: auto -> light -> dark ------------------------------------------ */

  var THEMES = ["auto", "light", "dark"];

  function setTheme(theme) {
    root.setAttribute("data-theme", theme);
    try { localStorage.setItem("docodin-theme", theme); } catch (e) { /* private mode */ }
  }

  function initTheme() {
    document.querySelectorAll(".theme-toggle").forEach(function (button) {
      button.addEventListener("click", function () {
        var current = root.getAttribute("data-theme") || "auto";
        var next = THEMES[(THEMES.indexOf(current) + 1) % THEMES.length];
        setTheme(next);
        button.setAttribute("title", "Colour theme: " + next);
      });
    });
  }

  /* --- search --------------------------------------------------------------------------- */

  var STOPWORDS = {};
  ("a an and are as at be but by for if in into is it no not of on or such that the their " +
    "then there these they this to was will with").split(" ").forEach(function (w) {
    STOPWORDS[w] = true;
  });

  var index = null;
  var waiting = [];

  function loadIndex(callback) {
    if (index) { callback(index); return; }
    if (window.DOCODIN_SEARCH_INDEX) {
      index = prepareIndex(window.DOCODIN_SEARCH_INDEX);
      callback(index);
      return;
    }
    waiting.push(callback);
    if (waiting.length > 1) return;
    var script = document.createElement("script");
    script.src = base + "searchindex.js";
    script.onload = function () {
      index = prepareIndex(window.DOCODIN_SEARCH_INDEX || { docs: [], sections: [], terms: {} });
      waiting.forEach(function (cb) { cb(index); });
      waiting = [];
    };
    document.head.appendChild(script);
  }

  function prepareIndex(raw) {
    raw.words = Object.keys(raw.terms).sort();
    raw.bySection = raw.sections.map(function (s) {
      return { doc: s[0], title: s[1], anchor: s[2], lower: s[1].toLowerCase() };
    });
    return raw;
  }

  function words(text) {
    return (text.toLowerCase().match(/[\p{L}\p{N}_]+/gu) || []).filter(function (w) {
      return w.length >= 2 && !STOPWORDS[w];
    });
  }

  // Binary search for the first index word >= prefix.
  function lowerBound(list, prefix) {
    var lo = 0, hi = list.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (list[mid] < prefix) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  // Scores by document: every query word must match (exactly, or as a prefix for
  // half the weight; the last word as typed is a prefix).
  function search(ix, query) {
    var terms = words(query);
    if (!terms.length) return [];
    var scores = null;
    terms.forEach(function (term) {
      var found = {};
      var i = lowerBound(ix.words, term);
      for (; i < ix.words.length && ix.words[i].indexOf(term) === 0; i++) {
        var word = ix.words[i];
        var factor = word === term ? 1 : 0.5;
        ix.terms[word].forEach(function (p) {
          found[p[0]] = (found[p[0]] || 0) + p[1] * factor;
        });
      }
      if (scores === null) { scores = found; return; }
      var both = {};
      Object.keys(scores).forEach(function (d) {
        if (found[d] !== undefined) both[d] = scores[d] + found[d];
      });
      scores = both;
    });
    return Object.keys(scores || {}).map(function (d) {
      var doc = +d;
      return { doc: doc, score: scores[d], section: bestSection(ix, doc, terms) };
    }).sort(function (a, b) { return b.score - a.score; });
  }

  function bestSection(ix, doc, terms) {
    var best = null;
    ix.bySection.forEach(function (s) {
      if (s.doc !== doc || best) return;
      if (terms.some(function (t) { return s.lower.indexOf(t) >= 0; })) best = s;
    });
    return best;
  }

  function resultUrl(ix, r) {
    var url = base + ix.docs[r.doc].n + ".html";
    return r.section ? url + "#" + r.section.anchor : url;
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c];
    });
  }

  function snippet(text, terms) {
    var lower = text.toLowerCase();
    var at = -1;
    terms.some(function (t) { at = lower.indexOf(t); return at >= 0; });
    var start = Math.max(0, at - 70);
    var piece = (start > 0 ? "…" : "") + text.substr(start, 220) + "…";
    var html = escapeHtml(piece);
    terms.forEach(function (t) {
      var re = new RegExp("(" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + ")", "gi");
      html = html.replace(re, "<mark>$1</mark>");
    });
    return html;
  }

  function initDropdown() {
    var form = document.querySelector(".search-form");
    if (!form) return;
    var input = form.querySelector("input");
    var box = form.querySelector(".search-dropdown");
    var active = -1;

    function render(ix, query) {
      var results = search(ix, query).slice(0, 8);
      active = -1;
      if (!query.trim()) { box.hidden = true; return; }
      if (!results.length) {
        box.innerHTML = "<div class=\"empty\">No results for “" + escapeHtml(query) + "”</div>";
      } else {
        box.innerHTML = results.map(function (r) {
          var where = r.section ? escapeHtml(r.section.title) : "";
          return "<a href=\"" + resultUrl(ix, r) + "\">" + escapeHtml(ix.docs[r.doc].t) +
            (where ? "<span class=\"where\">" + where + "</span>" : "") + "</a>";
        }).join("");
      }
      box.hidden = false;
    }

    input.addEventListener("input", function () {
      var query = input.value;
      loadIndex(function (ix) { render(ix, query); });
    });
    input.addEventListener("keydown", function (event) {
      var links = box.querySelectorAll("a");
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        if (!links.length) return;
        event.preventDefault();
        active = (active + (event.key === "ArrowDown" ? 1 : -1) + links.length) % links.length;
        links.forEach(function (a, i) { a.classList.toggle("active", i === active); });
      } else if (event.key === "Enter" && active >= 0 && links[active]) {
        event.preventDefault();
        window.location.href = links[active].href;
      } else if (event.key === "Escape") {
        box.hidden = true;
        input.blur();
      }
    });
    document.addEventListener("click", function (event) {
      if (!form.contains(event.target)) box.hidden = true;
    });
  }

  function initSearchPage() {
    var list = document.querySelector(".search-results");
    if (!list) return;
    var query = new URLSearchParams(window.location.search).get("q") || "";
    var input = document.querySelector(".search-form input");
    if (input) input.value = query;
    var summary = document.querySelector(".search-summary");
    if (!query.trim()) return;
    loadIndex(function (ix) {
      var terms = words(query);
      var results = search(ix, query);
      summary.textContent = results.length ?
        results.length + " page" + (results.length === 1 ? "" : "s") + " match “" + query + "”." :
        "No pages match “" + query + "”.";
      list.innerHTML = results.map(function (r) {
        var doc = ix.docs[r.doc];
        return "<li><a href=\"" + resultUrl(ix, r) + "\">" + escapeHtml(doc.t) + "</a>" +
          (r.section ? "<span class=\"where\">" + escapeHtml(r.section.title) + "</span>" : "") +
          "<p class=\"snippet\">" + snippet(doc.x, terms) + "</p></li>";
      }).join("");
    });
  }

  /* --- on this page --------------------------------------------------------------------- */

  function initScrollSpy() {
    var links = Array.prototype.slice.call(document.querySelectorAll(".dod-toc a[href^='#']"));
    if (!links.length || !("IntersectionObserver" in window)) return;
    var targets = links.map(function (a) {
      return document.getElementById(decodeURIComponent(a.getAttribute("href").slice(1)));
    });
    var visible = {};
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
      var current = null;
      targets.forEach(function (t, i) { if (t && visible[t.id] && current === null) current = i; });
      if (current === null) return;
      links.forEach(function (a, i) { a.classList.toggle("active", i === current); });
    }, { rootMargin: "0px 0px -65% 0px" });
    targets.forEach(function (t) { if (t) observer.observe(t); });
  }

  /* --- code blocks ---------------------------------------------------------------------- */

  function initCopyButtons() {
    document.querySelectorAll(".dod-article pre").forEach(function (pre) {
      var frame = document.createElement("div");
      frame.className = "code-frame";
      pre.parentNode.insertBefore(frame, pre);
      frame.appendChild(pre);
      var button = document.createElement("button");
      button.type = "button";
      button.className = "copy-button";
      button.textContent = "Copy";
      button.addEventListener("click", function () {
        var clone = pre.cloneNode(true);
        clone.querySelectorAll(".ln").forEach(function (n) { n.remove(); });
        var text = clone.textContent;
        var done = function () {
          button.textContent = "Copied";
          setTimeout(function () { button.textContent = "Copy"; }, 1400);
        };
        if (navigator.clipboard) navigator.clipboard.writeText(text).then(done, function () {});
      });
      frame.appendChild(button);
    });
  }

  /* --- keyboard and drawers ------------------------------------------------------------ */

  function initKeys() {
    document.addEventListener("keydown", function (event) {
      var tag = (event.target.tagName || "").toLowerCase();
      var typing = tag === "input" || tag === "textarea" || event.target.isContentEditable;
      if (event.key === "/" && !typing) {
        var input = document.querySelector(".search-form input");
        if (input) {
          event.preventDefault();
          var nav = document.getElementById("nav-toggle");
          if (nav && window.innerWidth <= 900) nav.checked = true;
          input.focus();
        }
      } else if (event.key === "Escape") {
        ["nav-toggle", "toc-toggle"].forEach(function (id) {
          var box = document.getElementById(id);
          if (box) box.checked = false;
        });
      }
    });
    document.querySelectorAll(".dod-toc a, .nav-tree a").forEach(function (a) {
      a.addEventListener("click", function () {
        var box = document.getElementById("toc-toggle");
        if (box) box.checked = false;
      });
    });
  }

  /* keep the current page visible in the navigation */
  function revealCurrent() {
    var current = document.querySelector(".nav-tree a.current-page");
    var inner = document.querySelector(".dod-sidebar-inner");
    if (!current || !inner) return;
    var top = current.offsetTop - inner.clientHeight / 3;
    if (top > 0) inner.scrollTop = top;
  }

  function init() {
    initTheme();
    initDropdown();
    initSearchPage();
    initScrollSpy();
    initCopyButtons();
    initKeys();
    revealCurrent();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
