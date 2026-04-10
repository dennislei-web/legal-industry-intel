// ============================================================
// Lawsnote 法官案件數 100% 全自動查詢
// ============================================================
// 使用方式：
// 1. Chrome 開 lawsnote.com 並登入
// 2. F12 → Console
// 3. 貼上此腳本按 Enter
// 4. 放著不管！腳本會自動跑完全部 1689 位法官
// 5. 完成後自動下載 JSON
// 6. 用 Python: python import_lawsnote_cases.py 匯入 DB
//
// 原理：利用 Lawsnote SPA 的 History API 搜尋，
//        不離開頁面所以 JS 不會中斷
//
// 控制：
//   查看進度: Object.keys(JSON.parse(localStorage.__ln_auto||'{}')).length
//   暫停: window.__ln_stop = true
//   繼續: 重新貼腳本
//   清除重來: localStorage.removeItem('__ln_auto'); localStorage.removeItem('__ln_names')
// ============================================================

(async function() {
  'use strict';

  // 載入或恢復名單
  let names = JSON.parse(localStorage.getItem('__ln_names') || '[]');
  if (!names.length) {
    console.log('📋 載入法官名單...');
    try {
      const KEY = 'sb_publishable_NvTWZM6IGgc_Jn8iCXFvaA_QnvJsstM';
      let all = [];
      for (let offset = 0; ; offset += 1000) {
        const r = await fetch(
          `https://zpbkeyhxyykbvownrngf.supabase.co/rest/v1/jy_judges?select=name,court_name&order=name.asc&offset=${offset}&limit=1000`,
          { headers: { apikey: KEY, Authorization: 'Bearer ' + KEY } }
        );
        const d = await r.json();
        if (!Array.isArray(d) || !d.length) break;
        all = all.concat(d);
        if (d.length < 1000) break;
      }
      names = all.map(j => j.name);
      localStorage.setItem('__ln_names', JSON.stringify(names));
      console.log('✅ 載入 ' + names.length + ' 位');
    } catch(e) {
      // CORS 失敗時用 fetch 從本地檔案
      console.error('❌ Supabase CORS 失敗。請手動設定：');
      console.log('在 Claude Code terminal 執行：');
      console.log('  python -c "import json; f=open(\'judge_names.json\'); d=json.load(f); print(\'localStorage.setItem(\\\"__ln_names\\\", JSON.stringify(\' + json.dumps([j[\'name\'] for j in d]) + \'))\');"');
      console.log('然後把輸出貼到 Console 執行，再重新貼本腳本');
      return;
    }
  }

  const done = JSON.parse(localStorage.getItem('__ln_auto') || '{}');
  const todo = names.filter(n => done[n] === undefined);

  console.log(`📊 總: ${names.length}, 完成: ${Object.keys(done).length}, 待查: ${todo.length}`);

  if (!todo.length) {
    console.log('🎉 全部完成！');
    download();
    return;
  }

  console.log(`🚀 開始！預估 ${Math.round(todo.length * 4 / 60)} 分鐘`);
  console.log('💡 放著不管，會自動跑完。暫停: window.__ln_stop = true');

  window.__ln_stop = false;

  // 確保在搜尋頁面
  if (!window.location.pathname.includes('/search/')) {
    window.location.href = '/search/all/' + encodeURIComponent('法官：' + todo[0]);
    // 頁面會重新載入，需要重新貼腳本
    // 但我們可以用 beforeunload 來處理...
    // 或者直接等到用戶在搜尋頁面時再執行
    console.log('⏳ 導航中...頁面載入後請重新貼腳本一次');
    return;
  }

  // 核心：用搜尋框 + 按鈕觸發搜尋（SPA 不重新載入頁面）
  for (let i = 0; i < todo.length; i++) {
    if (window.__ln_stop) {
      console.log('⏸ 已暫停。重新貼腳本繼續。');
      break;
    }

    const name = todo[i];

    // 方法：直接修改 URL + 觸發 SPA 路由
    // Lawsnote 用 React Router，pushState 不會觸發路由
    // 改用搜尋框輸入 + 按搜尋按鈕
    const searchInput = document.querySelector('input[type="search"], input[placeholder*="關鍵字"], textarea');
    const searchBtn = document.querySelector('button:has(svg), button[type="submit"]') ||
                      [...document.querySelectorAll('button')].find(b => b.textContent.includes('搜尋'));

    if (searchInput && searchBtn) {
      // 清空並輸入新搜尋詞
      const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype, 'value'
      )?.set || Object.getOwnPropertyDescriptor(
        window.HTMLTextAreaElement.prototype, 'value'
      )?.set;

      if (nativeInputValueSetter) {
        nativeInputValueSetter.call(searchInput, '法官：' + name);
      } else {
        searchInput.value = '法官：' + name;
      }
      searchInput.dispatchEvent(new Event('input', { bubbles: true }));
      searchInput.dispatchEvent(new Event('change', { bubbles: true }));

      // 按搜尋
      await sleep(300);
      searchBtn.click();

      // 等結果載入
      let count = 0;
      for (let attempt = 0; attempt < 30; attempt++) {
        await sleep(500);
        const text = document.body.innerText;
        const m = text.match(/共(\d[\d,]*)筆結果/);
        if (m) {
          count = parseInt(m[1].replace(/,/g, ''));
          break;
        }
      }

      done[name] = count;

      // 每 10 筆存一次
      if ((Object.keys(done).length) % 10 === 0) {
        localStorage.setItem('__ln_auto', JSON.stringify(done));
        console.log(`[${Object.keys(done).length}/${names.length}] ${name}: ${count.toLocaleString()}`);
      }

      await sleep(1000);
    } else {
      console.error('找不到搜尋框，請確認在 Lawsnote 搜尋頁面');
      break;
    }
  }

  // 最終存檔
  localStorage.setItem('__ln_auto', JSON.stringify(done));
  console.log(`✅ 本輪完成: ${Object.keys(done).length}/${names.length}`);

  if (Object.keys(done).length >= names.length) {
    download();
  }

  function download() {
    const blob = new Blob([JSON.stringify(done, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'lawsnote_judge_cases_' + new Date().toISOString().slice(0, 10) + '.json';
    a.click();
    console.log('💾 已下載！用 python import_lawsnote_cases.py 匯入 DB');
  }

  function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
})();
