// ================================================================
// Lawsnote 法官案件數批量查詢腳本 (自啟動版)
// ================================================================
// 使用方式：
// 1. 在 Chrome 開啟 lawsnote.com 並登入
// 2. 開啟 DevTools Console (F12)
// 3. 貼上此腳本並執行
// 4. 腳本會自動開始搜尋，每位法官約 4 秒
// 5. 每次頁面重新載入後，再次貼上此腳本即可從上次中斷處繼續
//    （進度保存在 localStorage）
// 6. 全部完成後自動下載 JSON
// 7. 用 Python: python import_lawsnote_cases.py 寫入 DB
//
// 控制指令（在 Console 執行）：
//   localStorage.getItem('__ln_done')  // 查看已完成的結果
//   localStorage.removeItem('__ln_done')  // 清除進度重新開始
//   localStorage.removeItem('__ln_todo')  // 清除法官名單重新載入
// ================================================================

(async function() {
  const SUPABASE_URL = 'https://zpbkeyhxyykbvownrngf.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_NvTWZM6IGgc_Jn8iCXFvaA_QnvJsstM';

  // 步驟 1：如果在搜尋結果頁，讀取結果數
  const isSearchPage = window.location.pathname.includes('/search/');
  if (isSearchPage) {
    const done = JSON.parse(localStorage.getItem('__ln_done') || '{}');
    const todo = JSON.parse(localStorage.getItem('__ln_todo') || '[]');
    const idx = parseInt(localStorage.getItem('__ln_idx') || '0');

    // 等搜尋結果載入
    await new Promise(r => setTimeout(r, 2000));

    const match = document.body.innerText.match(/共(\d[\d,]*)筆結果/);
    const count = match ? parseInt(match[1].replace(/,/g, '')) : 0;

    if (todo[idx]) {
      const name = todo[idx].name;
      const court = todo[idx].court_name;
      done[name] = { count, court };
      localStorage.setItem('__ln_done', JSON.stringify(done));

      const nextIdx = idx + 1;
      localStorage.setItem('__ln_idx', String(nextIdx));

      console.log(`✓ [${nextIdx}/${todo.length}] ${name} (${court}): ${count.toLocaleString()}`);
      document.title = `[${nextIdx}/${todo.length}] ${name}: ${count.toLocaleString()}`;

      if (nextIdx < todo.length) {
        // 延遲後自動導航到下一位
        setTimeout(() => {
          const nextName = todo[nextIdx].name;
          window.location.href = '/search/all/' + encodeURIComponent('法官：' + nextName);
        }, 2000);
        return;
      } else {
        console.log('🎉 全部完成！正在下載結果...');
        const blob = new Blob([JSON.stringify(done, null, 2)], { type: 'application/json' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'lawsnote_judge_cases_' + new Date().toISOString().slice(0, 10) + '.json';
        a.click();
        document.title = `✅ 完成! ${Object.keys(done).length} 位法官`;
        return;
      }
    }
  }

  // 步驟 2：如果沒有待查名單，從 Supabase 載入
  let todo = JSON.parse(localStorage.getItem('__ln_todo') || '[]');
  if (!todo.length) {
    console.log('📋 從 Supabase 載入法官名單...');
    let allJudges = [];
    let offset = 0;
    while (true) {
      try {
        const resp = await fetch(
          `${SUPABASE_URL}/rest/v1/jy_judges?select=name,court_name&order=name.asc&offset=${offset}&limit=1000`,
          { headers: { 'apikey': SUPABASE_KEY, 'Authorization': 'Bearer ' + SUPABASE_KEY } }
        );
        const data = await resp.json();
        if (!Array.isArray(data) || !data.length) break;
        allJudges = allJudges.concat(data);
        offset += 1000;
        if (data.length < 1000) break;
      } catch(e) {
        console.error('載入失敗:', e);
        break;
      }
    }
    todo = allJudges;
    localStorage.setItem('__ln_todo', JSON.stringify(todo));
    console.log(`📊 載入 ${todo.length} 位法官`);
  }

  // 跳過已查的
  const done = JSON.parse(localStorage.getItem('__ln_done') || '{}');
  let startIdx = parseInt(localStorage.getItem('__ln_idx') || '0');

  // 如果已全部完成
  if (startIdx >= todo.length) {
    console.log(`✅ 已全部完成 (${Object.keys(done).length} 位)`);
    return;
  }

  console.log(`🚀 從第 ${startIdx + 1} 位開始 (已完成: ${Object.keys(done).length}, 剩餘: ${todo.length - startIdx})`);
  console.log('⏱ 預估時間:', Math.round((todo.length - startIdx) * 4 / 60), '分鐘');

  // 開始搜尋
  const nextName = todo[startIdx].name;
  setTimeout(() => {
    window.location.href = '/search/all/' + encodeURIComponent('法官：' + nextName);
  }, 1000);
})();
