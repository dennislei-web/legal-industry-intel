// ============================================================
// Lawsnote 法官案件數自動查詢（每頁自動執行版）
// ============================================================
// 使用方式：
// 1. Chrome DevTools → Sources → Snippets → 新增 snippet
// 2. 貼上此腳本，命名為 "lawsnote"
// 3. 開 lawsnote.com 並登入
// 4. 右鍵 snippet → Run（或 Ctrl+Enter）
// 5. 腳本會自動：讀取當前頁結果 → 導航下一位 → 等新頁載入
// 6. 每次新頁面載入後，再次 Run snippet 即可繼續
//    （或設定 DevTools 的 "Run snippet on page load" 自動執行）
//
// ⚡ 最快方式：在搜尋結果頁面按 Ctrl+Enter 重複執行
//    腳本會自動讀取結果、存檔、導航下一位
//
// 查看進度: localStorage.__ln_progress
// 清除重來: localStorage.removeItem('__ln_progress')
// ============================================================

(function() {
  const STORAGE_KEY = '__ln_progress';
  const state = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{"done":{},"idx":0,"names":[]}');

  // 如果在搜尋結果頁，讀取結果
  if (window.location.pathname.includes('/search/')) {
    const match = document.body.innerText.match(/共(\d[\d,]*)筆結果/);
    const count = match ? parseInt(match[1].replace(/,/g, '')) : 0;

    if (state.names[state.idx]) {
      const name = state.names[state.idx];
      state.done[name] = count;
      state.idx++;
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));

      const total = state.names.length;
      const doneCount = Object.keys(state.done).length;
      console.log(`✓ [${doneCount}/${total}] ${name}: ${count.toLocaleString()}`);
      document.title = `[${doneCount}/${total}] ${name}: ${count.toLocaleString()}`;

      // 導航下一位（2秒後）
      if (state.idx < total) {
        const next = state.names[state.idx];
        console.log(`→ 下一位: ${next}（2秒後自動導航）`);
        setTimeout(() => {
          window.location.href = '/search/all/' + encodeURIComponent('法官：' + next);
        }, 2000);
      } else {
        console.log('🎉 全部完成！正在下載 JSON...');
        document.title = '✅ DONE: ' + doneCount + ' judges';
        const blob = new Blob([JSON.stringify(state.done, null, 2)], {type:'application/json'});
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'lawsnote_cases_' + new Date().toISOString().slice(0,10) + '.json';
        a.click();
      }
      return;
    }
  }

  // 如果不在搜尋頁或沒有名單，初始化
  if (!state.names.length) {
    console.log('📋 首次執行：正在從 Supabase 載入法官名單...');
    const KEY = 'sb_publishable_NvTWZM6IGgc_Jn8iCXFvaA_QnvJsstM';
    fetch(`https://zpbkeyhxyykbvownrngf.supabase.co/rest/v1/jy_judges?select=name&order=name.asc&limit=2000`, {
      headers: { 'apikey': KEY, 'Authorization': 'Bearer ' + KEY }
    }).then(r => r.json()).then(data => {
      if (Array.isArray(data) && data.length) {
        state.names = data.map(j => j.name);
        state.idx = 0;
        state.done = {};
        localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
        console.log(`✅ 載入 ${state.names.length} 位法官`);
        console.log('🚀 開始查詢...');
        const first = state.names[0];
        window.location.href = '/search/all/' + encodeURIComponent('法官：' + first);
      } else {
        console.error('❌ Supabase 載入失敗（可能 CORS），手動注入名單：');
        console.log('localStorage.setItem("__ln_progress", JSON.stringify({done:{},idx:0,names:["名1","名2",...]}))');
      }
    }).catch(e => {
      console.error('❌ 載入失敗:', e.message);
    });
    return;
  }

  // 有名單但不在搜尋頁 → 開始/繼續
  const doneCount = Object.keys(state.done).length;
  console.log(`📊 進度: ${doneCount}/${state.names.length}, 下一位: ${state.names[state.idx]}`);
  console.log('🚀 導航中...');
  window.location.href = '/search/all/' + encodeURIComponent('法官：' + state.names[state.idx]);
})();
