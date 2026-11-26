(function () {
  var AUTH = /^\/(login|register|forgot-password|reset-password)\/?$/;

  function sync() {
    var path = location.pathname || "/";
    document.documentElement.classList.toggle("amhar-auth-bg", AUTH.test(path));
  }

  function wrap(name) {
    var orig = history[name];
    if (typeof orig !== "function") return;
    history[name] = function () {
      var result = orig.apply(this, arguments);
      sync();
      return result;
    };
  }

  sync();
  wrap("pushState");
  wrap("replaceState");
  window.addEventListener("popstate", sync);
  document.addEventListener("DOMContentLoaded", sync);
})();
