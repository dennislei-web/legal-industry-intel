@echo off
rem 職安署霸凌調查專家名冊每日同步（Windows 排程器 wbie_expert_sync 呼叫，台北 03:10）
rem GH Actions runner 被政府站擋海外 IP，故走本機；log 追加至 wbie_sync.log
cd /d C:\projects\legal-industry-intel\scripts
set PYTHONIOENCODING=utf-8
python wbie_sync.py >> wbie_sync.log 2>&1
