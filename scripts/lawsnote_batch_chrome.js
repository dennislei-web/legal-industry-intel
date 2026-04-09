// ================================================================
// Lawsnote 法官案件數批量查詢腳本
// ================================================================
// 使用方式：
// 1. 在 Chrome 開啟 lawsnote.com 並登入
// 2. 開啟 DevTools Console (F12)
// 3. 貼上此腳本並執行
// 4. 腳本會自動逐一搜尋每位法官，每位約 3-4 秒
// 5. 完成後自動下載 JSON 結果檔
// 6. 用 Python 執行: python import_lawsnote_cases.py 寫入 DB
// ================================================================

(async function lawsnoteBatch() {
  // 從 Supabase 取法官名單
  const SUPABASE_URL = 'https://zpbkeyhxyykbvownrngf.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_NvTWZM6IGgc_Jn8iCXFvaA_QnvJsstM';

  console.log('📋 取得法官名單...');

  let allJudges = [];
  let offset = 0;
  while (true) {
    const resp = await fetch(
      `${SUPABASE_URL}/rest/v1/jy_judges?select=name,court_name&order=name.asc&offset=${offset}&limit=1000`,
      { headers: { 'apikey': SUPABASE_KEY, 'Authorization': 'Bearer ' + SUPABASE_KEY } }
    );
    const data = await resp.json();
    if (!data.length) break;
    allJudges = allJudges.concat(data);
    offset += 1000;
    if (data.length < 1000) break;
  }

  // 排除已查詢的（檢查 localStorage）
  const done = JSON.parse(localStorage.getItem('__ln_done') || '{}');
  const todo = allJudges.filter(j => !done[j.name]);

  console.log(`📊 法官總數: ${allJudges.length}, 已查: ${Object.keys(done).length}, 待查: ${todo.length}`);

  if (!todo.length) {
    console.log('✅ 全部完成！');
    downloadResults(done);
    return;
  }

  // 逐一搜尋
  for (let i = 0; i < todo.length; i++) {
    const name = todo[i].name;
    const court = todo[i].court_name;

    // 導航
    window.location.href = '/search/all/' + encodeURIComponent('法官：' + name);

    // 等頁面載入（透過 polling title 變化）
    await new Promise(resolve => {
      let attempts = 0;
      const check = setInterval(() => {
        attempts++;
        const match = document.body?.innerText?.match(/共(\d[\d,]*)筆結果/);
        if (match || attempts > 20) {
          clearInterval(check);
          const count = match ? parseInt(match[1].replace(/,/g, '')) : 0;
          done[name] = { count, court };
          localStorage.setItem('__ln_done', JSON.stringify(done));
          document.title = `[${i+1}/${todo.length}] ${name}: ${count}`;
          console.log(`[${i+1}/${todo.length}] ${name} (${court}): ${count}`);
          resolve();
        }
      }, 500);
    });

    // 延遲
    await new Promise(r => setTimeout(r, 2000));
  }

  console.log('✅ 全部完成！');
  downloadResults(done);

  function downloadResults(data) {
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'lawsnote_judge_cases_' + new Date().toISOString().slice(0, 10) + '.json';
    a.click();
    console.log('💾 結果已下載');
  }
})();
