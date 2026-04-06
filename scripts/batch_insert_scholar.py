"""批次插入 20 篇 Google Scholar / 期刊論文到 academic_papers"""
import os
import requests
import urllib3
from dotenv import load_dotenv

urllib3.disable_warnings()
load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

SUPABASE_URL = os.environ['SUPABASE_URL']
SERVICE = os.environ['SUPABASE_SERVICE_KEY']
PAT = 'sbp_38230f930e11f126f51c0ffd234cc9066884ba74'
REF = 'zpbkeyhxyykbvownrngf'

# 取得 user_id
r = requests.post(f'{SUPABASE_URL}/auth/v1/admin/generate_link',
    headers={'apikey': SERVICE, 'Authorization': f'Bearer {SERVICE}', 'Content-Type': 'application/json'},
    json={'type': 'magiclink', 'email': 'dennis.lei@010.tw'}, verify=False, timeout=20)
user_id = r.json()['id']
print(f'user_id: {user_id}')

papers = [
    {'title': '現代律師執業環境之研究', 'authors': ['鄭美愛', '鄭文婷'], 'year': 2014,
     'venue': '北商學報 第25/26期', 'degree_type': 'journal',
     'abstract': '本文從律師之養成過程、執業現況以及法律服務市場之供需面，探討台灣律師的執業環境。研究發現律師人數急遽增加，但法律服務市場成長有限，導致律師收入下降與執業困境加劇。',
     'keywords': ['律師執業', '法律服務市場', '律師人數', '執業環境'],
     'source_url': 'https://acad.ntub.edu.tw/var/file/4/1004/img/289/25&26-2.pdf'},
    {'title': '台灣地區法律服務產業經營管理要素探討—依不同規模事務所為區分', 'authors': ['劉明哲'], 'year': 2006,
     'venue': '國立臺灣大學 EMBA', 'degree_type': 'thesis_master',
     'abstract': '探討台灣不同規模法律事務所之經營管理要素差異，分析大型、中型、小型事務所在人力資源、知識管理、行銷策略等面向的不同做法與挑戰。',
     'keywords': ['法律服務業', '事務所規模', '經營管理', '人力資源'],
     'source_url': 'https://www.airitilibrary.com/Article/Detail/U0001-2807200611442700'},
    {'title': '淺論人工智慧於法律服務業之應用', 'authors': ['全國律師聯合會'], 'year': 2022,
     'venue': '全國律師聯合會 研究報告', 'degree_type': 'journal',
     'abstract': '探討人工智慧技術在法律服務業的應用現況與前景，包括AI法律研究工具、智能合約審閱、法律文件自動化等面向，並分析對律師執業模式的可能影響。',
     'keywords': ['人工智慧', 'AI', '法律服務業', 'LegalTech'],
     'source_url': 'https://www.twba.org.tw/upload/article/20221230/6cab20002a2c40c78c61ceedce7a5684/6cab20002a2c40c78c61ceedce7a5684.pdf'},
    {'title': '人工智慧法律科技對律師倫理的衝擊', 'authors': ['陳豐奇', '陳鋕雄'], 'year': 2019,
     'venue': '全國律師 期刊', 'degree_type': 'journal',
     'abstract': '分析AI法律科技對傳統律師倫理規範的衝擊，探討律師使用AI工具時可能涉及的保密義務、注意義務、利益衝突等倫理問題，提出因應建議。',
     'keywords': ['律師倫理', '人工智慧', '法律科技', '倫理衝擊'],
     'source_url': 'https://tpl.ncl.edu.tw/NclService/JournalContentDetail?SysId=A19027026'},
    {'title': '法律科技對台灣律師及企業法務之影響及因應—從大型語言模型談起', 'authors': ['未提供'], 'year': 2025,
     'venue': '國立臺灣大學 管理學院創業創新管理碩士在職專班', 'degree_type': 'thesis_master',
     'abstract': '探討大型語言模型(LLM)等AI技術對台灣律師與企業法務工作的影響，分析法律專業人員如何因應AI帶來的變革。',
     'keywords': ['大型語言模型', 'LLM', '法律科技', '企業法務', 'AI'],
     'source_url': 'https://tdr.lib.ntu.edu.tw/jspui/retrieve/37f29a2f-7638-44fc-96f6-222214f51ebf/ntu-114-1.pdf'},
    {'title': '台灣律師人口需求量之實證研究', 'authors': ['法務部'], 'year': 2017,
     'venue': '法務部 委託研究報告', 'degree_type': 'other',
     'abstract': '我國律師人數之需求若取最大區間，應介於4,084人至16,427人之間。報告分析律師供給與需求的經濟學模型，探討律師人數與法律服務品質的關係。',
     'keywords': ['律師人數', '供需分析', '法律市場', '實證研究'],
     'source_url': 'https://www.rjsd.moj.gov.tw/rjsdweb/common/WebList3.aspx?menu=INF_COMMON_LAWYER'},
    {'title': '市場變小了？如何促進律師產業的創新動能', 'authors': ['郭榮彥'], 'year': 2020,
     'venue': '法律白話文運動 專題研究', 'degree_type': 'journal',
     'abstract': '台灣法律服務業產值約650億台幣，但律師僅滿足不到20%的法律需求市場。探討律師產業如何透過創新開闢新藍海。',
     'keywords': ['律師產業', '創新動能', '法律市場', '藍海策略'],
     'source_url': 'https://plainlaw.me/posts/律師市場變小了？'},
    {'title': '台灣只有20%訴訟案有委任律師，是誰把律師產業做小了？', 'authors': ['陳明呈'], 'year': 2019,
     'venue': '關鍵評論網 法律專題', 'degree_type': 'journal',
     'abstract': '分析台灣訴訟案件委任律師比例偏低的原因，探討法律扶助制度擴大後對律師市場的影響，以及中型事務所面臨的生存困境。',
     'keywords': ['委任律師', '訴訟市場', '法律扶助', '中型事務所'],
     'source_url': 'https://www.thenewslens.com/article/112736'},
    {'title': '律師過剩時代 如何為法律人開創多元職涯？', 'authors': ['台北律師公會'], 'year': 2024,
     'venue': '在野法潮 DISSENT 特別企劃', 'degree_type': 'journal',
     'abstract': '探討律師市場飽和下法律人的多元職涯發展方向，包括企業法務、法律科技創業、國際法務、公共利益法律等路徑分析。',
     'keywords': ['律師過剩', '多元職涯', '法律人', '職涯發展'],
     'source_url': 'https://dissent.tba.org.tw/special/4074'},
    {'title': '台灣的律師人口真的夠嗎？—從市場經濟研究看律師總量的需求', 'authors': ['司法改革基金會'], 'year': 2018,
     'venue': '民間司法改革基金會 研究報告', 'degree_type': 'other',
     'abstract': '從市場經濟學角度分析台灣律師人口是否飽和，比較各國律師人口比例，探討律師考試錄取率與市場需求的關係。',
     'keywords': ['律師人口', '市場經濟', '律師考試', '國際比較'],
     'source_url': 'https://digital.jrf.org.tw/articles/1624'},
    {'title': '用統計看法律產業的發展—突破律師市場飽和迷思開闢新藍海', 'authors': ['商業周刊'], 'year': 2020,
     'venue': '商業周刊 法律專欄', 'degree_type': 'journal',
     'abstract': '運用統計數據分析法律產業實際發展趨勢，破解律師市場飽和迷思，提出律師可以拓展的新興服務領域與市場機會。',
     'keywords': ['法律產業', '統計分析', '市場飽和', '新藍海'],
     'source_url': 'https://bwc.businessweekly.com.tw/flash/law/202008/blog1.html'},
    {'title': '當AI來襲，律師執業的機會與衝擊', 'authors': ['台北律師公會'], 'year': 2023,
     'venue': '在野法潮 DISSENT', 'degree_type': 'journal',
     'abstract': '分析AI技術對律師執業帶來的機會與威脅，從合約審閱自動化、法律研究輔助、訴訟預測等面向探討AI如何改變律師工作模式。',
     'keywords': ['AI', '律師執業', '法律科技', '自動化'],
     'source_url': 'https://dissent.tba.org.tw/special/3216/'},
    {'title': 'LegalTech法律科技新創台灣發展現狀與期許', 'authors': ['黃沛聲'], 'year': 2021,
     'venue': '創投律師Bryan 專欄', 'degree_type': 'journal',
     'abstract': '盤點台灣LegalTech新創公司的發展現狀，分析法律科技在台灣的市場機會與挑戰，比較美國、日本、中國的LegalTech發展。',
     'keywords': ['LegalTech', '法律科技', '新創', '台灣'],
     'source_url': 'https://bryan.law/legaltech-startuptw/'},
    {'title': 'AI技術引進法律服務業是利是弊？美日中台常見的Legal Tech服務', 'authors': ['關鍵評論網'], 'year': 2020,
     'venue': '關鍵評論網 科技專題', 'degree_type': 'journal',
     'abstract': '比較分析美國、日本、中國、台灣四地的Legal Tech服務發展，探討AI技術引入法律服務業的利弊及各國發展差異。',
     'keywords': ['Legal Tech', 'AI', '國際比較', '法律服務'],
     'source_url': 'https://www.thenewslens.com/article/133726'},
    {'title': '人工智慧法律思辨：台灣人工智慧的司法應用', 'authors': ['人工智慧法律國際研究基金會'], 'year': 2023,
     'venue': '人工智慧法律國際研究基金會 研究報告', 'degree_type': 'other',
     'abstract': '深入探討人工智慧在台灣司法系統的應用，包括智慧法院、量刑預測、司法文書自動化等，分析AI對司法正義的影響。',
     'keywords': ['人工智慧', '司法應用', '智慧法院', '量刑預測'],
     'source_url': 'https://www.intlailaw.org/article_d.php?lang=tw&tb=4&id=840'},
    {'title': '2023 Lawsnote JobBoard 台灣律師職涯市場報告', 'authors': ['Lawsnote'], 'year': 2023,
     'venue': 'Lawsnote JobBoard 年度報告', 'degree_type': 'other',
     'abstract': '調查430+位律師，涵蓋薪資分佈(60%落在71-110萬)、工作年資(50%在3年以下)、事務所規模(71.7%為5人以下)、招募重視面向等。台灣律師市場最完整的職涯數據。',
     'keywords': ['律師職涯', '薪資調查', '就業市場', '年度報告'],
     'source_url': 'https://jobboard.lawsnote.com/blogs/213'},
    {'title': '律師今日的執業困境', 'authors': ['虛擬律師'], 'year': 2020,
     'venue': 'Medium 法律專欄', 'degree_type': 'journal',
     'abstract': '分析2011年律師考試錄取率大幅提高後，律師執業環境的結構性變化：受雇難找、薪資下降、獨立執業門檻提高等困境。',
     'keywords': ['執業困境', '律師考試', '就業市場', '薪資'],
     'source_url': 'https://medium.com/vlawyer/律師今日的執業困境-38d2d9856a7c'},
    {'title': '現行律師倫理規範、律師懲戒規則、律師法之合憲性探討', 'authors': ['謝諒獲'], 'year': 2016,
     'venue': '全國律師 期刊', 'degree_type': 'journal',
     'abstract': '從憲法角度檢視現行律師倫理規範與懲戒制度的合憲性問題，探討律師自律與國家管制的界限。',
     'keywords': ['律師倫理', '律師懲戒', '違憲審查', '律師法'],
     'source_url': 'https://tpl.ncl.edu.tw/NclService/JournalContentDetail?SysId=A99012626'},
    {'title': 'AI律師完全指南：從害怕被取代到擁抱AI法律助手', 'authors': ['台灣法律機器人'], 'year': 2025,
     'venue': 'TW LawBot 研究報告', 'degree_type': 'other',
     'abstract': '最新的AI法律助手使用指南，分析LegalBenchmarks數據顯示AI在偵測合約瑕疵與異常風險時覆蓋率達83%，探討律師如何有效整合AI工具。',
     'keywords': ['AI律師', '法律助手', 'LegalBenchmarks', '合約審閱'],
     'source_url': 'https://twlawbot.com/legal-knowledge/category/legal-tech/ai-lawyer-complete-guide'},
    {'title': 'Lawsnote觀點：AI與法律—從人工智慧的長處與短處看未來的律師產業變化', 'authors': ['Lawsnote'], 'year': 2026,
     'venue': 'Lawsnote 部落格 專題分析', 'degree_type': 'journal',
     'abstract': '深度分析AI在法律產業的長處(大量文件處理、判決分析、合約比對)與短處(法律推理、價值判斷、客戶關係)，預測律師產業未來轉型方向。',
     'keywords': ['AI', '律師產業', '產業變化', '未來展望'],
     'source_url': 'https://blog.lawsnote.com/2026/01/lawsnote-ai-legal-3/'},
]

# 去重
H_SB = {'apikey': SERVICE, 'Authorization': f'Bearer {SERVICE}'}
r = requests.get(f'{SUPABASE_URL}/rest/v1/academic_papers?select=source_url&limit=1000',
                 headers=H_SB, verify=False, timeout=30)
existing = {row['source_url'] for row in r.json() if row.get('source_url')}

to_insert = []
for p in papers:
    if p['source_url'] in existing:
        print(f'SKIP: {p["title"][:40]}')
        continue
    to_insert.append({
        'user_id': user_id,
        'title': p['title'],
        'authors': p.get('authors'),
        'year': p.get('year'),
        'venue': p.get('venue'),
        'degree_type': p.get('degree_type'),
        'abstract': p.get('abstract'),
        'keywords': p.get('keywords'),
        'source': 'scholar',
        'source_url': p['source_url'],
        'import_status': 'metadata_only',
        'chunk_count': 0,
    })

print(f'\n要插入: {len(to_insert)} 篇')
if to_insert:
    r = requests.post(f'{SUPABASE_URL}/rest/v1/academic_papers',
        headers={**H_SB, 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        json=to_insert, verify=False, timeout=60)
    print(f'INSERT: {r.status_code}')
    if r.status_code not in (200, 201, 204):
        print(f'ERR: {r.text[:500]}')

# 建 abstract chunks
H_MGMT = {'Authorization': f'Bearer {PAT}', 'Content-Type': 'application/json'}
r2 = requests.post(
    f'https://api.supabase.com/v1/projects/{REF}/database/query',
    headers=H_MGMT, json={'query': """
DO $$ DECLARE p RECORD; block TEXT; cnt INT := 0; BEGIN
  FOR p IN SELECT * FROM academic_papers WHERE chunk_count = 0 AND abstract IS NOT NULL LOOP
    block := E'標題：' || p.title || E'\\n作者：' || COALESCE(array_to_string(p.authors, ', '), '未提供')
      || E'\\n年份：' || COALESCE(p.year::text, '未知') || E'\\n來源：' || COALESCE(p.venue, '未知')
      || E'\\n關鍵字：' || COALESCE(array_to_string(p.keywords, E'、'), '')
      || E'\\n\\n摘要：\\n' || p.abstract;
    INSERT INTO paper_chunks (paper_id, chunk_index, section, content, char_count) VALUES (p.id, 0, '論文摘要', block, LENGTH(block));
    UPDATE academic_papers SET chunk_count = 1, full_text_length = LENGTH(block) WHERE id = p.id;
    cnt := cnt + 1;
  END LOOP;
END $$;
"""}, verify=False, timeout=60)
print(f'Chunks: {r2.status_code}')

# 統計
r3 = requests.post(f'https://api.supabase.com/v1/projects/{REF}/database/query',
    headers=H_MGMT, json={'query': """
SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE source='ndltd') AS ndltd,
       COUNT(*) FILTER (WHERE source='scholar') AS scholar,
       COUNT(*) FILTER (WHERE chunk_count > 0) AS with_chunks
FROM academic_papers
"""}, verify=False, timeout=30)
print(f'\n最終: {r3.text}')
