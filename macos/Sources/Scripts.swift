import Foundation

/// JavaScript injected into the web UI. The Windows build runs inside WebView2,
/// and stremio-web-shell-fixes checks for `window.chrome.webview`, so we emulate
/// that API on top of WKWebView message handlers and reuse the upstream scripts.
enum Scripts {
    /// Emulates WebView2's `window.chrome.webview` (postMessage + 'message' events).
    /// Native code delivers messages through `window.__stremioShellDeliver(string)`.
    static func webviewShim(origin: String) -> String {
        """
        (function() {
          if (window.top !== window) return;
          if (location.origin !== \(jsString(origin))) return;
          if (window.chrome && window.chrome.webview) return;
          var listeners = [];
          window.chrome = window.chrome || {};
          window.chrome.webview = {
            postMessage: function(msg) {
              window.webkit.messageHandlers.stremioShell.postMessage(typeof msg === 'string' ? msg : JSON.stringify(msg));
            },
            addEventListener: function(type, cb) { if (type === 'message') listeners.push(cb); },
            removeEventListener: function(type, cb) {
              var i = listeners.indexOf(cb);
              if (i >= 0) listeners.splice(i, 1);
            }
          };
          Object.defineProperty(window, '__stremioShellDeliver', {
            value: function(data) {
              var ev = { data: data };
              listeners.slice().forEach(function(cb) {
                try { cb(ev); } catch (e) { console.error('shell listener failed', e); }
              });
            }
          });
        })();
        """
    }

    /// Based on upstream EXEC_SHELL_SCRIPT. Upstream calls initShellComm() once on
    /// window load; in WKWebView the load event can fire before the web UI's
    /// transport listens for it, and the signal is lost. So we keep the function
    /// the page defines and call it until the transport sends its init message.
    static func execShell(origin: String) -> String {
        """
        try {
            if (location.origin === \(jsString(origin)) && window.self === window.top && !window.qt) {
              var connected = false;
              var post = window.chrome.webview.postMessage;
              window.qt = {
                webChannelTransport: {
                  send: function(msg) {
                    if (!connected && typeof msg === 'string' && /"type":\\s*3\\b/.test(msg)) connected = true;
                    post(msg);
                  },
                  onmessage: (ev) => {
                    console.log('Received message from shell:', ev);
                  }
                }
              };

              window.chrome.webview.addEventListener('message', (ev) => {
                window.qt.webChannelTransport.onmessage(ev);
              });

              var initFn = null;
              Object.defineProperty(window, 'initShellComm', {
                configurable: true,
                get: function() { return initFn; },
                set: function(v) { initFn = v; }
              });

              var started = Date.now();
              var kick = function() {
                if (connected) return;
                if (typeof initFn === 'function') {
                  try { initFn(); } catch (e) { console.error('initShellComm failed', e); }
                } else if (Date.now() - started > 15000) {
                  const errorMessage = {
                    type: 6, object: "transport", method: "handleInboundJSON", id: 888,
                    args: [ "app-error", [ "shellComm" ] ]
                  };
                  post(JSON.stringify(errorMessage));
                  return;
                }
                setTimeout(kick, 250);
              };
              window.addEventListener('DOMContentLoaded', kick);
            }
        } catch(e) {
            console.error("Error exec initShellComm:", e);
        }
        """
    }

    /// STREMIO_DEBUG=1 only: mirrors console output and page errors into stremio.log.
    static let consoleForwarder = """
    (function() {
      function post(level, args) {
        try {
          var text = Array.prototype.map.call(args, function(a) {
            if (a instanceof Error) return a.stack || String(a);
            if (typeof a === 'object') { try { return JSON.stringify(a); } catch (e) {} }
            return String(a);
          }).join(' ');
          window.webkit.messageHandlers.stremioNative.postMessage({ type: 'console', level: level, text: text.slice(0, 2000) });
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error'].forEach(function(level) {
        var orig = console[level];
        console[level] = function() { post(level, arguments); return orig.apply(console, arguments); };
      });
      window.addEventListener('error', function(e) { post('uncaught', [e.message + ' @ ' + e.filename + ':' + e.lineno]); });
      window.addEventListener('unhandledrejection', function(e) { post('unhandledrejection', [e.reason]); });
    })();
    """

    /// Upstream INJECTED_KEYDOWN_SCRIPT (F5 / Ctrl+F5 refresh).
    static let keydown = """
    (function() {
        window.addEventListener('keydown', function(event) {
            if (event.code === 'F5' && window.chrome && window.chrome.webview) {
                event.preventDefault();
                const ctrlPressed = event.ctrlKey || event.metaKey;
                window.chrome.webview.postMessage(JSON.stringify({
                  type: 6, object: "transport", method: "handleInboundJSON", id: 999,
                  args: [ "refresh", [ ctrlPressed ? "all" : "no" ] ]
                }));
            }
        });
    })();
    """

    /// The web UI toggles fullscreen with the DOM Fullscreen API. WKWebView's own
    /// element fullscreen would move the page into a separate window and away from
    /// the mpv layer, so we fake the API and make the whole NSWindow fullscreen instead.
    static let fullscreenPolyfill = """
    (function() {
      if (window.top !== window) return;
      var fsEl = null;
      function post(on) {
        try { window.webkit.messageHandlers.stremioNative.postMessage({ type: 'fullscreen', value: on }); } catch (e) {}
      }
      function fire() {
        setTimeout(function() {
          document.dispatchEvent(new Event('fullscreenchange'));
          document.dispatchEvent(new Event('webkitfullscreenchange'));
        }, 0);
      }
      function def(name, getter) {
        try { Object.defineProperty(Document.prototype, name, { configurable: true, get: getter }); } catch (e) {}
      }
      def('fullscreenElement', function() { return fsEl; });
      def('webkitFullscreenElement', function() { return fsEl; });
      def('webkitCurrentFullScreenElement', function() { return fsEl; });
      def('fullscreen', function() { return !!fsEl; });
      def('webkitIsFullScreen', function() { return !!fsEl; });
      def('fullscreenEnabled', function() { return true; });
      def('webkitFullscreenEnabled', function() { return true; });
      function request() {
        var el = this;
        if (fsEl !== el) { fsEl = el; post(true); fire(); }
        return Promise.resolve();
      }
      function exit() {
        if (fsEl) { fsEl = null; post(false); fire(); }
        return Promise.resolve();
      }
      Element.prototype.requestFullscreen = request;
      Element.prototype.webkitRequestFullscreen = request;
      Element.prototype.webkitRequestFullScreen = request;
      Document.prototype.exitFullscreen = exit;
      Document.prototype.webkitExitFullscreen = exit;
      Document.prototype.webkitCancelFullScreen = exit;
      // Like a browser: Escape leaves fullscreen and the page never sees the key.
      window.addEventListener('keydown', function(e) {
        if (e.key === 'Escape' && fsEl) {
          e.preventDefault();
          e.stopImmediatePropagation();
          document.exitFullscreen();
        }
      }, true);
      // Called by native code when the window enters/leaves fullscreen on its own.
      Object.defineProperty(window, '__stremioShellSetFullscreen', {
        value: function(on) {
          if (on && !fsEl) { fsEl = document.documentElement; fire(); }
          else if (!on && fsEl) { fsEl = null; fire(); }
        }
      });
    })();
    """

    /// Upstream INJECTED_BUTTON_SCRIPT, shown on pages outside the web UI.
    static let backButton = """
    (function() {
      if (document.getElementById('goBackStremioBtn')) return;
      var btn = document.createElement('button');
      btn.id = 'goBackStremioBtn';
      btn.style.position = 'fixed';
      btn.style.bottom = '15px';
      btn.style.right = '15px';
      btn.style.zIndex = '9999';
      btn.style.backgroundColor = '#121024';
      btn.style.color = 'white';
      btn.style.border = 'none';
      btn.style.borderRadius = '30px';
      btn.style.padding = '12px 20px';
      btn.style.fontSize = '16px';
      btn.style.fontWeight = 'bold';
      btn.style.display = 'flex';
      btn.style.alignItems = 'center';
      btn.style.boxShadow = '0 4px 6px rgba(0,0,0,0.1)';
      btn.style.cursor = 'pointer';
      btn.style.transition = 'background-color 0.3s ease';
      btn.addEventListener('mouseenter', function() { btn.style.backgroundColor = '#211e39'; });
      btn.addEventListener('mouseleave', function() { btn.style.backgroundColor = '#121024'; });
      var img = document.createElement('img');
      img.src = 'https://stremio.zarg.me/images/stremio_symbol.png';
      img.alt = 'Logo';
      img.style.height = '24px';
      img.style.width = '24px';
      img.style.marginRight = '8px';
      img.addEventListener('error', function() { img.style.display = 'none'; });
      var txt = document.createElement('span');
      txt.textContent = 'Back to Stremio';
      btn.appendChild(img);
      btn.appendChild(txt);
      btn.addEventListener('click', function() {
        window.webkit.messageHandlers.stremioNative.postMessage({ type: 'home' });
      });
      document.body.appendChild(btn);
    })();
    """

    /// Port of MakeInjectCssScript.
    static func injectCss(id: String, css: String) -> String {
        let b64 = Data(css.utf8).base64EncodedString()
        return """
        (function(){try{
          if(window.top!==window)return;
          var id='webmods-css-\(id)';
          function inject(){
            try{
              var root=document.head||document.documentElement||document.body;
              if(!root){
                document.addEventListener('DOMContentLoaded',inject,{once:true});
                setTimeout(inject,25);
                return;
              }
              if(document.getElementById(id))return;
              var bin=atob('\(b64)');
              var bytes=new Uint8Array(bin.length);
              for(var i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
              var s=document.createElement('style');
              s.id=id;
              s.textContent=new TextDecoder('utf-8').decode(bytes);
              root.appendChild(s);
            }catch(e){console.error('webmods css inject failed:',e);}
          }
          inject();
        }catch(e){console.error('webmods css failed:',e);}})();
        """
    }

    /// Port of MakeInjectJsScript.
    static func injectJs(js: String) -> String {
        let b64 = Data(js.utf8).base64EncodedString()
        return """
        (function(){try{
          if(window.top!==window)return;
          var bin=atob('\(b64)');
          var bytes=new Uint8Array(bin.length);
          for(var i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
          (0,eval)(new TextDecoder('utf-8').decode(bytes));
        }catch(e){console.error('webmods js exec failed:',e);}})();
        """
    }

    /// Encodes a Swift string as a JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }
}
