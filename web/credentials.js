/* Credentials-page logic — QR codes, copy-to-clipboard, force rotation.
 * Served from the same token directory as index.html so 'self' CSP allows it.
 * Scripts are at the end of <body>, so the DOM is fully parsed when this runs.
 * No inline handlers — everything wired via event delegation inside an IIFE.
 */
(function () {

  // ── QR codes ────────────────────────────────────────────────────────────────
  function makeQR(canvasId, srcId) {
    try {
      new QRCode(document.getElementById(canvasId), {
        text: document.getElementById(srcId).textContent.trim(),
        width: 160, height: 160,
        colorDark: '#000000', colorLight: '#ffffff',
        correctLevel: QRCode.CorrectLevel.M
      });
    } catch (e) {
      var el = document.getElementById(canvasId);
      if (el) el.textContent = '(QR недоступен)';
    }
  }
  makeQR('qr-canvas',    'vless-uri');
  makeQR('ss-qr-canvas', 'ss-uri');

  // ── Copy buttons (event delegation) ─────────────────────────────────────────
  // Buttons carry either data-copy="VALUE" or data-copy-from="ELEMENT_ID".
  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.copy-btn');
    if (!btn) return;

    var text = btn.dataset.copy;
    if (!text) {
      var src = btn.dataset.copyFrom;
      if (src) {
        var el = document.getElementById(src);
        text = el ? el.textContent.trim() : '';
      }
    }
    if (!text) return;

    _copyText(text, btn);
  });

  function _copyText(text, btn) {
    var origText = btn.textContent;
    function onSuccess() {
      btn.textContent = 'Скопировано';
      btn.classList.add('copied');
      setTimeout(function () {
        btn.textContent = origText;
        btn.classList.remove('copied');
      }, 1500);
    }
    // Prefer async Clipboard API; fall back to execCommand for HTTP / older browsers.
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(onSuccess).catch(function () {
        _legacyCopy(text, onSuccess);
      });
    } else {
      _legacyCopy(text, onSuccess);
    }
  }

  function _legacyCopy(text, onSuccess) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;opacity:0;top:0;left:0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    try { if (document.execCommand('copy')) onSuccess(); } catch (e) {}
    document.body.removeChild(ta);
  }

  // ── Force rotation (event delegation) ────────────────────────────────────────
  // Buttons carry data-rotate="xray|mtg".
  // Flow: POST → 202/409 → recursive setTimeout poll until running=false → reload.
  // Recursive setTimeout (not setInterval) ensures fetches never overlap.
  var POLL_INTERVAL_MS = 2000;
  var POLL_TIMEOUT_MS  = 90000;

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.rotate-now-btn[data-rotate]');
    if (!btn || btn.disabled) return;
    _startRotation(btn.dataset.rotate, btn);
  });

  function _startRotation(type, btn) {
    var origText = btn.textContent;
    btn.disabled = true;
    btn.textContent = '⟳ Запуск…';

    fetch('rotate/' + type, { method: 'POST' })
      .then(function (resp) {
        if (resp.status === 202 || resp.status === 409) {
          btn.textContent = resp.status === 409 ? '⟳ Уже идёт…' : '⟳ Ротация…';
          _pollRotation(type, btn, origText, Date.now());
        } else {
          throw new Error('HTTP ' + resp.status);
        }
      })
      .catch(function () {
        _showBtnError(btn, origText);
      });
  }

  // Recursive poll — each call schedules the next only after the fetch settles,
  // so there is never more than one in-flight request at a time.
  function _pollRotation(type, btn, origText, startedAt) {
    setTimeout(function () {
      var elapsed = Date.now() - startedAt;
      if (elapsed >= POLL_TIMEOUT_MS) {
        location.reload();
        return;
      }

      fetch('rotate/' + type)
        .then(function (r) { return r.json(); })
        .then(function (data) {
          if (!data.running) {
            btn.textContent = '✓ Готово';
            btn.classList.add('rn-ok');
            setTimeout(function () { location.reload(); }, 800);
          } else {
            var left = Math.ceil((POLL_TIMEOUT_MS - (Date.now() - startedAt)) / 1000);
            btn.textContent = '⟳ Ротация (' + left + ' с)…';
            _pollRotation(type, btn, origText, startedAt);
          }
        })
        .catch(function () {
          // Network error during poll — reload to get fresh state.
          location.reload();
        });
    }, POLL_INTERVAL_MS);
  }

  function _showBtnError(btn, origText) {
    btn.textContent = '✗ Ошибка';
    btn.classList.add('rn-err');
    setTimeout(function () {
      btn.disabled = false;
      btn.textContent = origText;
      btn.classList.remove('rn-err');
    }, 3000);
  }

}());

