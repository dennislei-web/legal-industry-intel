# -*- coding: utf-8 -*-
"""Chambers 英文所名 → MOJ 中文所名對照（2026-08-29 人工查證）

查證方式：官網中英對照 / WebSearch / MOJ 名冊反查主持律師（moj_lawyers.office）。
None = 歸不了戶（缺口清單）：
  - Russin & Vecchi Ltd：外資老所（1976 台北），MOJ 中文登錄名不明
  - Top Team International = 頂尖國際專利商標事務所系？主持人洪澄文/吳珮琪為專利師，
    不在律師名冊 → 非律師所
  - Li & Cai = 聯誠國際智慧財產權事務所（專利師所，非律師名冊）
  - JC IP Group LLC = 將群智權集團（專利師所，非律師名冊）

注意陷阱（查證時踩過）：
  - Lexcel Partners = 惇安（不是常在！常在的英文名是 Tsar & Tsai）
  - Enlighten Law Group = 尚澄（不是明理；明理=Ming Li Law Office，陳金泉）
  - Chen & Lin = 宏鑑（官網 chenandlin.com，陳哲宏；非字面「陳林」）
  - Formosa Legal = 趙梅君律師事務所（趙梅君=Marianne Chao，前眾達工程爭議；
    與 Formosa Transnational 萬國是不同所）
  - Lo and Partners = 瑞勝國際（羅名威=Ming-Wei Lo，前眾達，Chambers 頁 email
    仍是 @jonesday.com）
  - Tsai, Lee & Chen = 連邦法律事務所（李世章 Victor S C Lee 反查）
  - Deep & Far = 道法法律事務所（蔡清福 C F Tsai 反查）
  - Chen & Chang = 眾才國際律師事務所（陳希佳 Helena Chen 反查）
"""

# 各評鑑來源英文所名變體 → Chambers canonical 名（rating_awards.py 用；
# canonical 再查 FIRM_MAP 得中文。查無 alias 者直接以原名查 FIRM_MAP）
FIRM_ALIAS = {
    "Lee and Li": "Lee and Li Attorneys-at-Law",
    "Lee and Li, Attorneys-at-Law": "Lee and Li Attorneys-at-Law",
    "Lin & Partners Attorneys-At-Law": "Lin & Partners",
    "Russin & Vecchi": "Russin & Vecchi Ltd",
    "Russin & Vecchi (International Legal Counsellors)": "Russin & Vecchi Ltd",
    "Tsar & Tsai Law Firm": "Tsar & Tsai",
    "Formosan Brothers Attorneys-at-Law": "Formosan Brothers",
    "Formosa Transnational": "Formosa Transnational Attorneys At Law",
    "Dacheng Taiwan Law Office": "Dacheng Law Offices, LLP",
    "Ching Cheng Attorneys": "Chingcheng Law Firm",
    "PwC Legal": "PuHua & Associates (PricewaterhouseCoopers Legal)",
    "Liang & Partners": "Liang & Partners Law Offices",
    "Tsai, Lee & Chen Patent Attorneys & Attorneys at Law": "Tsai, Lee & Chen",
    "Tsai Lee & Chen Patent Attorneys and Attorneys at Law": "Tsai, Lee & Chen",
    "Tsai Lee & Chen": "Tsai, Lee & Chen",
    "Chen & Lin Attorneys-at-Law": "Chen & Lin",
    "Formosan Brothers Attorneys at Law": "Formosan Brothers",
    "Saint Island Group": "Saint Island International Patent & Law Offices",
    "Saint Island International Patent Office": "Saint Island International Patent & Law Offices",
    "TIPLO Attorneys-at-Law": "Tiplo Attorneys-at-Law",
    "Deep & Far": "Deep & Far Attorneys-at-Law",
    "ChingCheng Attorneys at Law": "Chingcheng Law Firm",   # 慶辰官網 FB 英文名確認
    "Zoomlaw Attorneys at Law": "Zoomlaw Attorneys-at-Law",
    "Deloitte": "DTT Attorneys-at-Law",
    "Deloitte Legal": "DTT Attorneys-at-Law",
    # Dentons 全球聯盟在台成員即大成台灣（Dentons Taiwan = 大成台灣律師事務所，FB 官名）
    "Dentons": "Dacheng Law Offices, LLP",
    "Dentons Taiwan": "Dacheng Law Offices, LLP",
}

# 個人律師歸戶（pilot 保守版）：僅收「MOJ 名冊反查現職所 == Chambers firm 歸戶所」
# 雙重核對一致者；其餘 152 位存英文原名（英文名→中文名冊歸戶難度高，待官網中英對照批次）
# key = (name_en, firm_en)
LAWYER_MAP = {
    ("Jinquan Chen", "Ming Li Law Office"): "陳金泉",
    ("Yesin Chen", "Ye Sin Law Office"): "陳業鑫",
    ("James Hou", "Chingcheng Law Firm"): "侯慶辰",
    ("James C C Ku", "James C,C,Ku Law Office"): "古嘉諄",
    ("Marianne M Chao", "Formosa Legal"): "趙梅君",
    ("Helena Chen", "Chen & Chang, Attorneys-at-Law"): "陳希佳",
    ("C F Tsai", "Deep & Far Attorneys-at-Law"): "蔡清福",
    ("Arthur Shay", "Shay & Partners"): "謝穎青",
    ("Victor S C Lee", "Tsai, Lee & Chen"): "李世章",
    ("Ming-Wei Lo", "Lo and Partners"): "羅名威",
    ("Che-Hung Chen", "Chen & Lin"): "陳哲宏",
    # —— 三源批次（2026-08-29）：拼音吻合＋MOJ 名冊在籍雙重驗證 ——
    ("Chih-Poung Liou", "Stellex Law Firm"): "劉志鵬",
    ("Chien-Ting Yeh", "Chien Yeh Law Offices"): "葉建廷",
    ("Kunchou Tsai", "Enlighten Law Group"): "蔡昆洲",
    ("Dah-In Yeh", "Formosan Brothers"): "葉大殷",
    ("Chung-Teh Lee", "Lee, Tsai & Partners"): "李宗德",
    ("Jaclyn Tsai", "Lee, Tsai & Partners"): "蔡玉玲",
    ("Ross Yang", "PuHua & Associates (PricewaterhouseCoopers Legal)"): "楊敬先",
    ("Peter J Dernbach", "Winkler Partners"): "譚璧德",
    ("Frank Kung", "Liang & Partners Law Offices"): "孔繁琦",
    ("Heather Hsiao", "Eiger"): "蕭彣卉",            # 名冊唯一蕭姓＋官網英名在列
    ("Alan T Jih", "KPMG Law Firm"): "紀天昌",        # 上榜時任安侯主持律師；現職安律（名冊）
    ("Paul Chu", "Guo Ju Law Firm"): "朱應翔",        # 國巨創辦人；名冊 office=律師未提供
    ("Lun-Fan Lin", "Wu & Partners"): "林倫帆",       # 禾同唯一林姓，拼音完全吻合
    ("Ing-Chian Sun", "Nishimura & Asahi"): "孫櫻倩", # 西村朝日唯一孫姓，拼音吻合
    ("Yvonne Y F Lin", "Formosan Brothers"): "林怡芳", # Y F=怡芳，寰瀛林姓中唯一對應
    ("Po-Chien Chen", "Jones Day"): "陳博建",         # 拼音直接吻合＋名冊在籍
    ("Simon M. Yu", "Jones Day"): "余明賢",           # M.=Ming、名冊唯一余姓
    ("Simon Yu", "Jones Day"): "余明賢",
    ("Ming-Wei Lo", "Jones Day"): "羅名威",           # 已跳所瑞勝，Chambers/L500 頁仍掛眾達
    ("Chia-Ching Lee", "Lee and Li Attorneys-at-Law"): "李家慶",  # 官網 C. C. Lee
    ("Jackson Shuai-Sheng Huang", "Formosa Transnational Attorneys At Law"): "黃帥升",
    ("Peng-Kwang Chen", "Formosa Transnational Attorneys At Law"): "陳鵬光",
    ("Shao-Fan Lu", "Formosa Transnational Attorneys At Law"): "呂紹凡",
    ("Jacqueline Fu", "K&L Gates"): "傅昭倩",         # 高蓋茨名冊唯一傅姓
    ("Stacy Lo", "Lexcel Partners"): "羅祖芳",        # 惇安唯一羅姓，banking 領域吻合
}

FIRM_MAP = {
    "Lee and Li Attorneys-at-Law": "理律法律事務所",
    "Baker McKenzie": "國際通商法律事務所",
    "Tsar & Tsai": "常在國際法律事務所",
    "Lin & Partners": "恆業法律事務所",
    "Chen & Lin": "宏鑑法律事務所",
    "Jones Day": "眾達國際法律事務所",
    "Lee, Tsai & Partners": "理慈國際科技法律事務所",
    "LCS & Partners": "協合國際法律事務所",
    "Lexcel Partners": "惇安法律事務所",
    "K&L Gates": "高蓋茨法律事務所",
    "Formosa Transnational Attorneys At Law": "萬國法律事務所",
    "Stellex Law Firm": "有澤法律事務所",
    "Dacheng Law Offices, LLP": "大成台灣律師事務所",
    "Formosan Brothers": "寰瀛法律事務所",
    "Eiger": "艾格峰外國法事務律師事務所",
    "Formosa Legal": "趙梅君律師事務所",
    "Lo and Partners": "瑞勝國際法律事務所",
    "Winkler Partners": "博仲法律事務所",
    "Saint Island International Patent & Law Offices": "聖島國際法律事務所",
    "Tai E International Patent & Law Office": "台一國際法律事務所",
    "Tiplo Attorneys-at-Law": "台灣國際專利法律事務所",
    "Enlighten Law Group": "尚澄法律事務所",
    "Chien Yeh Law Offices": "建業法律事務所",
    "Nishimura & Asahi": "西村朝日台灣法律事務所",
    "PuHua & Associates (PricewaterhouseCoopers Legal)": "普華商務法律事務所",
    "DTT Attorneys-at-Law": "德勤商務法律事務所",
    "KPMG Law Firm": "安侯法律事務所",
    "LST&C Legal": "崇錦法律事務所",
    "James C,C,Ku Law Office": "古嘉諄律師事務所",
    "Chen & Chang, Attorneys-at-Law": "眾才國際律師事務所",
    "Ming Li Law Office": "明理法律事務所",
    "Ye Sin Law Office": "業鑫法律事務所",
    "Chingcheng Law Firm": "慶辰法律事務所",
    "Tsai, Lee & Chen": "連邦法律事務所",
    "Deep & Far Attorneys-at-Law": "道法法律事務所",
    "Wu & Partners": "禾同國際法律事務所",
    "Liang & Partners Law Offices": "環宇法律事務所",
    "Yangming Partners": "陽明國際律師事務所",
    "Shay & Partners": "太穎國際法律事務所",
    # —— 三源（Legal 500 / IFLR1000 / Asialaw）追加，2026-08-29 查證 ——
    "Guo Ju Law Firm": "國巨律師事務所",
    "Innovatus Law": "創拓國際法律事務所",
    "Zoomlaw Attorneys-at-Law": "眾律國際法律事務所",
    "Brain Trust International Law Firm": "群勝國際法律事務所",   # 歐陽泓，btlaw.com.tw footer
    "Chun Wei International Law Firm": "鈞威國際法律事務所",     # 海商，chun-wei.com.tw
    "Brainberg Law Firm": "朋博法律事務所",                      # 工程營建，brainberg.com.tw
    "Tayhuan Partners": "泰還國際法律事務所",                    # tayhuan.com
    # 缺口（歸不了 MOJ 戶）
    "Russin & Vecchi Ltd": None,
    "Top Team International Patent & Trademark Office": None,
    "Li & Cai Intellectual Property Office": None,
    "JC IP Group LLC": None,
    "JTJB Taipei": None,   # 新加坡 Joseph Tan Jude Benny 台北辦，MOJ 登錄名不明
}
