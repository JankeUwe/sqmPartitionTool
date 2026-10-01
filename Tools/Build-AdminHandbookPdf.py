# -*- coding: utf-8 -*-
"""
Baut das Admin-Handbuch (Markdown) als PDF fuer den Download auf powershelldba.de.

Aufruf (aus dem Repo-Stamm), Beispiel sqmPartitionTool:
    python Tools/Build-AdminHandbookPdf.py --md docs/AdminHandbuch.md \
        --out ../../powershelldba/pdba/sqmpartitiontool/downloads/sqmPartitionTool-AdminHandbuch.pdf \
        --product sqmPartitionTool \
        --subtitle "Automatic SQL Server table partitioning, runbooks for daily DBA operations"

Beispiel sqmDataTransfer:
    python Tools/Build-AdminHandbookPdf.py --md Docs/AdminHandbuch.md \
        --out ../../powershelldba/pdba/sqmtransfer/downloads/sqmDataTransfer-AdminHandbuch.pdf \
        --product sqmDataTransfer \
        --subtitle "Move table data between SQL Server instances, resumable and verified"

Das Datum auf dem Deckblatt kommt aus der Zeile "Stand: ..." im Markdown.
Benoetigt: Python 3, pip install markdown xhtml2pdf (Windows-Schriften Arial/Consolas).
Identisch in sqmPartitionTool und sqmDataTransfer - Aenderungen in beiden Repos nachziehen.
"""
import argparse
import datetime
import os
import re
import sys

import markdown
from reportlab.lib.fonts import addMapping
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from xhtml2pdf import default as pisa_default
from xhtml2pdf import pisa

FONT_DIR = os.path.join(os.environ.get('WINDIR', r'C:\Windows'), 'Fonts')

CSS = '''
@page {
    size: a4 portrait;
    margin: 2.0cm 1.9cm 2.2cm 1.9cm;
    @frame footer { -pdf-frame-content: footerContent; bottom: 0.9cm; margin-left: 1.9cm; margin-right: 1.9cm; height: 0.8cm; }
}
body { font-family: Body; font-size: 9.6pt; color: #1f2933; line-height: 1.45; }
h1 { font-size: 20pt; color: #102a43; border-bottom: 1.5pt solid #102a43; padding-bottom: 6pt; margin: 0 0 12pt 0; }
h2 { font-size: 14pt; color: #0b3c5d; border-bottom: 0.6pt solid #c9d2dc; padding-bottom: 3pt; margin: 16pt 0 8pt 0; -pdf-keep-with-next: true; }
h3 { font-size: 11pt; color: #0b3c5d; margin: 12pt 0 6pt 0; -pdf-keep-with-next: true; }
p { margin: 0 0 6pt 0; }
a { color: #1d5fa3; text-decoration: none; }
strong { color: #102a43; }
code { font-family: Mono; font-size: 8.6pt; color: #243b53; background-color: #eef2f6; }
pre { font-family: Mono; font-size: 8.0pt; background-color: #f4f6f9; border: 0.5pt solid #d9e2ec; padding: 6pt 6pt 8pt 6pt; margin: 4pt 0 12pt 0; line-height: 1.2; }
pre code { background-color: #f4f6f9; }
table { width: 100%; border-collapse: collapse; margin: 6pt 0 10pt 0; }
th { background-color: #0b3c5d; color: #ffffff; font-weight: bold; text-align: left; padding: 5pt; font-size: 8.8pt; }
td { border-bottom: 0.5pt solid #d9e2ec; padding: 5pt; vertical-align: top; font-size: 8.8pt; }
td code { font-size: 7.8pt; }
ul, ol { margin: 0 0 6pt 0; }
li { margin-bottom: 2pt; }
hr { color: #102a43; height: 1pt; margin: 10pt 0; }
.cover-kicker { text-align: center; color: #1d5fa3; font-size: 11pt; margin-top: 90pt; }
.cover-title { text-align: center; color: #102a43; font-size: 30pt; font-weight: bold; margin: 8pt 0 14pt 0; }
.cover-sub { text-align: center; color: #486581; font-size: 12pt; margin-bottom: 50pt; }
.cover-meta { text-align: center; color: #627d98; font-size: 9pt; }
#footerContent { text-align: center; color: #829ab1; font-size: 7.5pt; border-top: 0.5pt solid #d9e2ec; padding-top: 3pt; }
'''


def register_fonts():
    """Schriften direkt bei ReportLab registrieren. @font-face in xhtml2pdf kopiert die Datei unter
    Windows in eine Temp-Datei, die sich danach nicht mehr oeffnen laesst (TTFError)."""
    files = {'Body': 'arial.ttf', 'Body-Bold': 'arialbd.ttf', 'Body-Italic': 'ariali.ttf',
             'Body-BoldItalic': 'arialbi.ttf', 'Mono': 'consola.ttf', 'Mono-Bold': 'consolab.ttf'}
    for name, file in files.items():
        path = os.path.join(FONT_DIR, file)
        if not os.path.exists(path):
            sys.exit('Schrift fehlt: %s' % path)
        pdfmetrics.registerFont(TTFont(name, path))
    addMapping('Body', 0, 0, 'Body'); addMapping('Body', 1, 0, 'Body-Bold')
    addMapping('Body', 0, 1, 'Body-Italic'); addMapping('Body', 1, 1, 'Body-BoldItalic')
    addMapping('Mono', 0, 0, 'Mono'); addMapping('Mono', 1, 0, 'Mono-Bold')
    addMapping('Mono', 0, 1, 'Mono'); addMapping('Mono', 1, 1, 'Mono-Bold')
    pisa_default.DEFAULT_FONT['body'] = 'Body'
    pisa_default.DEFAULT_FONT['mono'] = 'Mono'


def build(md_path, out_path, product, subtitle):
    text = open(md_path, encoding='utf-8-sig').read()
    # Relative Links (CHANGELOG.md, README.md) zeigen im PDF ins Leere - auf GitHub umbiegen
    repo = os.path.basename(os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(md_path)), '..')))
    text = re.sub(r'\]\(\.\./([^)#]+)\)',
                  lambda m: '](https://github.com/JankeUwe/%s/blob/main/%s)' % (repo, m.group(1)), text)

    m = re.search(r'^Stand:\s*([^\n,]+)', text, re.M)
    stand = m.group(1).strip().rstrip('.') if m else datetime.date.today().isoformat()

    body = markdown.markdown(text, extensions=['tables', 'fenced_code', 'sane_lists', 'toc'])
    # Lange Funktionsnamen in Tabellenzellen laufen sonst in die Nachbarspalte (ReportLab bricht
    # nur an Leerzeichen um, Zero-Width-Space wird nicht unterstuetzt): ab 22 Zeichen nach dem
    # ersten Bindestrich umbrechen, z.B. "Invoke-" / "sqmTablePartitionConversion".
    def _wrap_code(k):
        txt = k.group(2)
        if len(txt) >= 22 and '-' in txt:
            txt = txt.replace('-', '-</code><br/><code>', 1)
        return k.group(1) + txt + k.group(3)
    body = re.sub(r'<td>.*?</td>', lambda c: re.sub(r'(<code>)(.*?)(</code>)', _wrap_code, c.group(0), flags=re.S),
                  body, flags=re.S)
    register_fonts()

    html = '''<html><head><meta charset="utf-8"><style>%s</style></head><body>
<div id="footerContent">%s Admin-Handbuch &middot; dtcSoftware / Uwe Janke &middot; www.powershelldba.de &middot; Seite <pdf:pagenumber/> von <pdf:pagecount/></div>
<div class="cover-kicker">Admin-Handbuch</div>
<div class="cover-title">%s</div>
<div class="cover-sub">%s</div>
<div class="cover-meta">dtcSoftware &middot; Uwe Janke &middot; www.powershelldba.de<br/>Stand: %s</div>
<pdf:nextpage/>
%s
</body></html>''' % (CSS, product, product, subtitle, stand, body)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'wb') as fh:
        result = pisa.CreatePDF(html, dest=fh, encoding='utf-8')
    if result.err:
        sys.exit('PDF-Erzeugung fehlgeschlagen (%d Fehler)' % result.err)
    print('PDF geschrieben: %s' % os.path.abspath(out_path))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--md', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--product', required=True)
    ap.add_argument('--subtitle', required=True)
    a = ap.parse_args()
    build(a.md, a.out, a.product, a.subtitle)
