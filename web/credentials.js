/* Credentials-page logic — QR codes and copy-to-clipboard.
 * Served from the same token directory as index.html so 'self' CSP allows it.
 * Scripts are at the end of <body>, so the DOM is fully parsed when this runs.
 */

// ── QR codes ──────────────────────────────────────────────────────────────────
(function () {
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
}());

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

  navigator.clipboard.writeText(text).then(function () {
    var orig = btn.textContent;
    btn.textContent = 'Скопировано';
    btn.classList.add('copied');
    setTimeout(function () {
      btn.textContent = orig;
      btn.classList.remove('copied');
    }, 1500);
  });
});
