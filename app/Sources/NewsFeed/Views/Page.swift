import Vapor

/// Build an HTML response with the right Content-Type header.
func htmlResponse(_ html: String) -> Response {
    let response = Response(status: .ok, body: .init(string: html))
    response.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
    return response
}

/// The shared HTML shell: doctype, head, CSS, HTMX script, body, runtime JS.
/// All view renderers use this — keeping it in one place means CSS changes
/// hit everything.
func page(title: String, body: String) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>\(htmlEscape(title))</title>
      <style>\(pageCSS)</style>
      <script src="https://unpkg.com/htmx.org@2.0.4"></script>
    </head>
    <body>
      \(body)
      <script>\(pageJS)</script>
    </body>
    </html>
    """
}

let pageJS = """
function openDetail() {
  document.body.classList.add('has-detail');
  document.querySelector('#detail')?.scrollTo({ top: 0, behavior: 'instant' });
}
function closeDetail() {
  document.body.classList.remove('has-detail');
  document.querySelectorAll('.card.selected').forEach(el => el.classList.remove('selected'));
  const d = document.getElementById('detail');
  if (d) d.innerHTML = '';
}
function escapeHTML(s) {
  return String(s || '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
document.body.addEventListener('htmx:beforeRequest', (e) => {
  const el = e.detail?.elt;
  if (!el || !el.classList.contains('card')) return;
  document.querySelectorAll('.card.selected').forEach(c => c.classList.remove('selected'));
  el.classList.add('selected');
  openDetail();
  const title = el.querySelector('h2')?.textContent?.trim() || 'this item';
  const timer = setTimeout(() => {
    const detail = document.getElementById('detail');
    if (detail) {
      detail.innerHTML = `
        <section class="detail-panel loading-state">
          <button class="close-btn" aria-label="close" onclick="closeDetail()">×</button>
          <div class="loading-row">
            <div class="spinner-lg"></div>
            <div class="loading-meta">
              <div class="loading-label">catching you up on</div>
              <div class="loading-article">${escapeHTML(title)}</div>
            </div>
          </div>
        </section>`;
    }
  }, 200);
  el._pulseLoadingTimer = timer;
});
document.body.addEventListener('htmx:afterRequest', (e) => {
  const el = e.detail?.elt;
  if (el && el._pulseLoadingTimer) {
    clearTimeout(el._pulseLoadingTimer);
    delete el._pulseLoadingTimer;
  }
  if (el && el.classList?.contains('engage') && e.detail?.successful) {
    const itemId = el.dataset.itemId;
    const isKeep = el.classList.contains('keep');
    const event = isKeep ? 'keep' : 'skip';
    document.querySelectorAll('.card[data-item-id="' + itemId + '"]').forEach(c => {
      c.classList.remove('kept', 'skipped');
      c.classList.add(event === 'keep' ? 'kept' : 'skipped');
    });
    const row = el.closest('.engagement-row');
    if (row) row.classList.add('voted', 'voted-' + event);
    el.disabled = true;
    setTimeout(() => closeDetail(), 420);
  }
});
document.body.addEventListener('htmx:afterSwap', (e) => {
  if (e.target && e.target.id === 'detail') openDetail();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && document.body.classList.contains('has-detail')) closeDetail();
});
"""

let pageCSS = """
:root{--bg:#fafafa;--card:#fff;--text:#1a1a1a;--muted:#666;--accent:#0070f3;--border:#eee;--ok:#16a34a;--err:#dc2626;--selected:#e3f2fd}
@media(prefers-color-scheme:dark){:root{--bg:#0a0a0a;--card:#141414;--text:#f0f0f0;--muted:#888;--accent:#3291ff;--border:#222;--ok:#4ade80;--err:#f87171;--selected:#0a1a2e}}
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Helvetica,Arial,sans-serif;background:var(--bg);color:var(--text)}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}

main.layout{display:block;max-width:720px;margin:0 auto;padding:24px 16px}
main.layout.single{max-width:720px}
.list{width:100%}
.detail{display:none}

@media(min-width:900px){
  body.has-detail main.layout{max-width:1440px;display:grid;grid-template-columns:minmax(360px,1fr) minmax(480px,1.4fr);gap:40px;align-items:start}
  body.has-detail .list{max-width:none}
  body.has-detail .detail{display:block;position:sticky;top:24px;max-height:calc(100vh - 48px);overflow-y:auto;padding:8px 4px 24px 4px;animation:slideInRight 0.2s ease-out}
}
@keyframes slideInRight{from{opacity:0;transform:translateX(12px)}to{opacity:1;transform:translateX(0)}}
@media(max-width:899px){
  body.has-detail .detail{display:block;position:fixed;inset:0;background:var(--bg);overflow-y:auto;padding:24px 16px;z-index:10;animation:slideInUp 0.2s ease-out}
  body.has-detail .list{visibility:hidden}
}
@keyframes slideInUp{from{opacity:0;transform:translateY(16px)}to{opacity:1;transform:translateY(0)}}

header{margin-bottom:20px;padding-bottom:10px;border-bottom:1px solid var(--border)}
h1{font-size:28px;margin-bottom:4px;letter-spacing:-0.02em}
.subtitle{color:var(--muted);font-size:13px}
.header-row{display:flex;align-items:flex-start;justify-content:space-between;gap:12px}
nav{margin-top:12px;font-size:13px;color:var(--muted)}
nav.btn-row{display:flex;gap:8px;flex-wrap:wrap}

/* outlined "pill" button style used for all navigation + the Update Interests link */
.btn-link{display:inline-flex;align-items:center;gap:4px;padding:6px 12px;border:1px solid var(--border);border-radius:6px;font-size:13px;color:var(--accent);background:transparent;text-decoration:none;transition:border-color 0.12s,background 0.12s}
.btn-link:hover{text-decoration:none;border-color:var(--accent);background:var(--card)}

/* identicon avatar (header → /account) */
.avatar{display:block;width:32px;height:32px;border-radius:50%;overflow:hidden;background:#f3f4f6;flex-shrink:0}
.avatar svg{display:block;width:100%;height:100%}
.avatar-link{display:inline-flex;align-items:center;padding:2px;border-radius:50%;border:1px solid var(--border);text-decoration:none;transition:border-color 0.12s}
.avatar-link:hover{text-decoration:none;border-color:var(--accent)}
.avatar-lg .avatar{width:64px;height:64px}

.card{padding:14px 12px;border-bottom:1px solid var(--border);cursor:pointer;transition:background 0.12s}
.card:hover{background:var(--card)}
.card.selected{background:var(--selected);border-radius:6px;border-bottom-color:transparent}
.meta{display:flex;gap:8px;align-items:center;margin-bottom:6px;font-size:12px;color:var(--muted);flex-wrap:wrap}
.badge{padding:2px 8px;border-radius:4px;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:0.5px}
.badge.tech{background:#e3f2fd;color:#0d47a1}
.badge.conversation{background:#fff3e0;color:#e65100}
.score{display:inline-block;min-width:26px;text-align:center;padding:2px 6px;border-radius:4px;font-size:11px;font-weight:700;background:#eee;color:#333}
.score-1,.score-2,.score-3{background:#f5f5f5;color:#888}
.score-4,.score-5{background:#e8f5e9;color:#1b5e20}
.score-6,.score-7{background:#c8e6c9;color:#1b5e20}
.score-8,.score-9,.score-10{background:#2e7d32;color:#fff}
@media(prefers-color-scheme:dark){
  .badge.tech{background:#0a1a2e;color:#60a5fa}
  .badge.conversation{background:#2a1a0a;color:#fbbf24}
  .score{background:#222;color:#ccc}
  .score-1,.score-2,.score-3{background:#1a1a1a;color:#555}
  .score-4,.score-5{background:#1a2a1a;color:#86efac}
  .score-6,.score-7{background:#1a3a1a;color:#bbf7d0}
  .score-8,.score-9,.score-10{background:#14532d;color:#fff}
}
.card h2{font-size:16px;font-weight:600;margin-bottom:6px;line-height:1.35;color:var(--text)}
.tldr{font-size:14px;color:var(--text);margin:6px 0;line-height:1.5}
.why{font-size:12px;color:var(--muted);margin:4px 0 0 0;font-style:italic}

.card.kept{position:relative}
.card.kept::after{content:"✓ kept";position:absolute;top:14px;right:10px;font-size:10px;font-weight:700;color:#16a34a;letter-spacing:0.04em;text-transform:uppercase}
.card.skipped{opacity:0.5}
.card.skipped::after{content:"skipped";position:absolute;top:14px;right:10px;font-size:10px;font-weight:600;color:var(--muted);letter-spacing:0.04em;text-transform:uppercase}
@media(prefers-color-scheme:dark){.card.kept::after{color:#4ade80}}

.detail-panel{position:relative;padding-right:40px}
.close-btn{position:absolute;top:0;right:0;width:32px;height:32px;border:none;background:transparent;color:var(--muted);font-size:24px;cursor:pointer;border-radius:4px;display:flex;align-items:center;justify-content:center}
.close-btn:hover{background:var(--border);color:var(--text)}
.detail-meta{display:flex;gap:10px;align-items:center;margin-bottom:12px;font-size:13px;color:var(--muted);flex-wrap:wrap}
.detail-title{font-size:22px;margin-bottom:8px;letter-spacing:-0.01em}
.detail-original{font-size:14px;margin-bottom:20px}
.catchup h2{font-size:13px;margin-top:20px;margin-bottom:6px;color:var(--muted);text-transform:uppercase;letter-spacing:0.05em;font-weight:700}
.catchup h2:first-child{margin-top:0}
.catchup p{margin:6px 0 12px;line-height:1.65;font-size:15px}
.catchup ul{margin:6px 0 12px 20px}
.catchup li{margin:6px 0;line-height:1.6;font-size:15px}

.iframe-mode{display:flex;flex-direction:column}
.banner-uncached{background:#fff7ed;border:1px solid #fdba74;color:#9a3412;padding:10px 12px;border-radius:6px;margin:8px 0 12px;font-size:13px;line-height:1.5}
@media(prefers-color-scheme:dark){.banner-uncached{background:#2a1a0a;border-color:#9a3412;color:#fbbf24}}
.muted{color:var(--muted);font-size:12px}
.iframe-wrap{margin-top:8px;border:1px solid var(--border);border-radius:6px;overflow:hidden;background:#fff;flex:1;min-height:480px}
.iframe-wrap iframe{width:100%;height:100%;min-height:480px;border:none;display:block}
@media(min-width:900px){
  body.has-detail .detail .iframe-wrap{min-height:calc(100vh - 260px)}
  body.has-detail .detail .iframe-wrap iframe{min-height:calc(100vh - 260px)}
}

.loading-state{min-height:240px;padding:8px 40px 24px 4px}
.loading-row{display:flex;gap:18px;align-items:center;padding:24px 0}
.spinner-lg{width:36px;height:36px;border:3px solid var(--border);border-top-color:var(--accent);border-radius:50%;animation:spin 0.7s linear infinite;flex-shrink:0}
.loading-meta{min-width:0}
.loading-label{font-size:11px;text-transform:uppercase;letter-spacing:0.08em;color:var(--muted);font-weight:700;margin-bottom:6px}
.loading-article{font-size:18px;font-weight:600;color:var(--text);line-height:1.35}

.engagement-row{display:flex;gap:12px;margin-top:24px;padding-top:16px;border-top:1px solid var(--border)}
.engage{flex:1;padding:12px 16px;font:inherit;font-size:14px;font-weight:600;border:1px solid var(--border);border-radius:8px;background:var(--card);color:var(--text);cursor:pointer;transition:all 0.15s ease;text-transform:lowercase;letter-spacing:0.02em}
.engage.keep:hover{background:#dcfce7;color:#14532d;border-color:#16a34a}
.engage.skip:hover{background:#fef2f2;color:#991b1b;border-color:#dc2626}
@media(prefers-color-scheme:dark){
  .engage.keep:hover{background:#052e16;color:#86efac;border-color:#16a34a}
  .engage.skip:hover{background:#2a0a0a;color:#fca5a5;border-color:#dc2626}
}
.engage:disabled{cursor:default;transform:scale(0.96);opacity:0.85}
.engagement-row.voted-keep .engage.keep{background:#16a34a;color:#fff;border-color:#16a34a}
.engagement-row.voted-skip .engage.skip{background:#dc2626;color:#fff;border-color:#dc2626}
.engagement-row.voted .engage:not(:disabled){opacity:0.35}

@keyframes spin{to{transform:rotate(360deg)}}

.capture-form,.auth-form,.onboard-form{display:flex;flex-direction:column;gap:12px;margin-top:16px;max-width:560px}
.capture-form label,.auth-form label,.onboard-form label{display:flex;flex-direction:column;gap:4px;font-size:13px;color:var(--muted)}
.capture-form textarea,.capture-form input,.auth-form input,.onboard-form textarea,.onboard-form input{font:inherit;padding:10px;border:1px solid var(--border);border-radius:6px;background:var(--card);color:var(--text);resize:vertical}
.capture-form button,.auth-form button,.onboard-form button{padding:10px 16px;font:inherit;font-weight:600;background:var(--accent);color:#fff;border:none;border-radius:6px;cursor:pointer;max-width:260px}
button.danger{background:#dc2626}
.flash{padding:10px 12px;border-radius:6px;margin:12px 0;font-size:14px;max-width:560px}
.flash.ok{background:#e8f5e9;color:var(--ok);border:1px solid var(--ok)}
.flash.err{background:#fef2f2;color:var(--err);border:1px solid var(--err)}

.auth-wrap{max-width:400px;margin:80px auto;padding:24px 16px}
.auth-footer{margin-top:16px;font-size:14px;color:var(--muted);text-align:center}
/* login/signup submit — right-aligned, smaller than the full-width form buttons elsewhere */
.auth-wrap .auth-form button{align-self:flex-end;padding:8px 18px;font-size:14px;max-width:none}

.onboard-form fieldset{border:1px solid var(--border);border-radius:6px;padding:12px 16px;margin-bottom:8px}
.onboard-form fieldset legend{padding:0 8px;font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:0.04em}
.onboard-form fieldset label{flex-direction:row;align-items:center;gap:8px;margin:6px 0;color:var(--text);font-size:14px;font-weight:normal}
.onboard-form fieldset label input{padding:0}

.account-section{padding:16px 0;border-bottom:1px solid var(--border);max-width:560px}
.account-section h2{font-size:16px;font-weight:600;margin-bottom:6px}
.account-section.danger-zone{border-top:1px solid #dc2626;margin-top:24px;padding-top:20px}
.account-section.danger-zone h2{color:#dc2626}
.btn-link{display:inline-block;padding:6px 12px;border:1px solid var(--border);border-radius:6px;font-size:13px}
.btn-link:hover{text-decoration:none;border-color:var(--accent)}
"""
