/* MOJ 律師查詢結果收成助手（書籤小程式／可貼到 DevTools Console）
 *
 * 在法務部律師查詢系統（lawyerbc.moj.gov.tw）自己打驗證碼查完、結果表出現後執行：
 * 讀「頁面上已經顯示的查詢結果」（含 id_no＝詳細頁資料雜湊值），開本站收成頁把資料寫進
 * Supabase moj_search_harvest。本程式不碰驗證碼、不自己送查詢、不讀詳細頁。
 *
 * 為什麼不在官網頁面直接 POST：官網 CSP 的 connect-src 只允許 'self' 與 etherscan，
 * 頁內 fetch 到 Supabase 會被瀏覽器擋下；改成「開新分頁導向收成頁、資料放網址 # 片段」
 * （# 片段不送任何伺服器），由收成頁寫入。
 *
 * 書籤版由 moj-harvest.html 依它自己的網址產生（__HARVEST_PAGE__ 會被換掉）；
 * 直接貼到 Console 時用正式站網址。
 */
(function () {
  var PAGE = '__HARVEST_PAGE__';
  if (!/^https?:/.test(PAGE)) PAGE = 'https://dennislei-web.github.io/legal-industry-intel/tools/moj-harvest.html';

  if (location.hostname !== 'lawyerbc.moj.gov.tw') {
    alert('請在法務部律師查詢系統（lawyerbc.moj.gov.tw）的查詢結果頁使用。');
    return;
  }
  var jq = window.jQuery;
  var $t = jq && jq('#table_QueryResults');
  if (!$t || !$t.length || typeof $t.bootstrapTable !== 'function') {
    alert('找不到查詢結果表，請先在官網完成一次查詢。');
    return;
  }

  var dec = function (v) {
    var s = (v === null || v === undefined) ? '' : String(v);
    if (typeof window.HtmlDecode === 'function') s = window.HtmlDecode(s);
    return s.replace(/\s+/g, ' ').trim();
  };
  var norm = function (s) { return String(s || '').replace(/台/g, '臺').replace(/[\s　]/g, ''); };

  /* 官網把「最近一次通過驗證碼的查詢條件」存在全域 lastSearch（換排序時沿用）。
   * 以它為準，才不會把殘留在畫面上的舊結果記到新打的查詢字串下。 */
  var ls = window.lastSearch;
  var okQuery = ls ? [ls.keyword, ls.name, ls.lic_no].filter(Boolean).join(' ').trim() : '';
  var shown = dec(jq('#searchKeyword').text());

  var data = [];
  try { data = $t.bootstrapTable('getData', { useCurrentPage: false }) || []; } catch (e) { data = []; }

  var q, rows;
  if (shown && okQuery && shown !== okQuery) {
    /* 最近一次按搜尋沒有成功（驗證碼錯，或官網回「找不到或超過 100 筆」），畫面上的表是上一次的結果 */
    if (!confirm('「' + shown + '」這次查詢沒有成功的結果（驗證碼錯誤，或官網顯示「找不到或超過 100 筆」）。\n\n'
      + '若官網顯示的是「找不到或超過 100 筆」，按「確定」記錄這條查過、0 筆；\n驗證碼打錯的話請按「取消」重查。')) return;
    q = shown;
    rows = [];
  } else {
    q = okQuery || shown;
    if (!q) q = (prompt('讀不到這次的查詢字串，請輸入剛才在官網查的字串：') || '').trim();
    if (!q) return;
    rows = data.map(function (r) {
      return {
        name: dec(r.name), lic_no: dec(r.now_lic_no), office: dec(r.office),
        guild_name: dec(r.guild_name), id_no: String(r.id_no || '').trim()
      };
    });
    var badHash = rows.filter(function (r) { return !/^0x[0-9a-fA-F]{64}$/.test(r.id_no); }).length;
    if (badHash && !confirm(badHash + ' 筆讀不到資料雜湊值（id_no），這些列會被略過。仍要送出嗎？')) return;
    if (/證|第/.test(q)) {
      var nq = norm(q);
      var off = rows.filter(function (r) { return norm(r.lic_no).indexOf(nq) !== 0; }).length;
      if (off && !confirm(off + '／' + rows.length + ' 筆證號不是以「' + q + '」開頭，'
        + '結果表可能還停在上一次查詢。確定要以「' + q + '」送出嗎？')) return;
    }
    if (!rows.length && !confirm('結果表是空的。要記錄「' + q + '」查過、0 筆嗎？')) return;
  }

  if (q.length > 60) { alert('查詢字串超過 60 字，請縮短後重查。'); return; }
  var payload = JSON.stringify({ q: q, rows: rows, t: Date.now() });
  window.open(PAGE + '#h=' + encodeURIComponent(payload), 'mojHarvest');
})();
