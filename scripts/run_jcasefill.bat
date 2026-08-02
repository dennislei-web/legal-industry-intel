@echo off
cd /d C:\projects\legal-industry-intel\scripts
set PYTHONIOENCODING=utf-8
python jcasefill.py 202001 202605 >> jcasefill_backfill.log 2>&1
