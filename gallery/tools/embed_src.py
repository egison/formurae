# -*- coding: utf-8 -*-
# Fill the gallery's full-source blocks: every
#   <details class="codebox" data-egi="<path relative to examples/>">...</details>
# in index.html gets its body replaced with the current content of that
# .egi file (escaped, with a line-count summary).  Idempotent -- run it
# again whenever an example changes.
import io, os, re, html

HERE = os.path.dirname(os.path.abspath(__file__))
GALLERY = os.path.join(HERE, '..')
EXAMPLES = os.path.join(GALLERY, '..', 'examples')
INDEX = os.path.join(GALLERY, 'index.html')

def block(m):
    rel = m.group('rel')
    path = os.path.join(EXAMPLES, rel)
    src = io.open(path, encoding='utf-8').read().rstrip('\n')
    nlines = src.count('\n') + 1
    body = html.escape(src, quote=False)
    # dim full-line comments for readability
    body = re.sub(r'(?m)^(--.*)$', r'<span class="c">\1</span>', body)
    return ('<details class="codebox" data-egi="%s"><summary>Egison ソース全文'
            '(%s・%d 行)</summary>\n<pre>%s</pre></details>'
            % (rel, os.path.basename(rel), nlines, body))

s = io.open(INDEX, encoding='utf-8').read()
pat = re.compile(r'<details class="codebox" data-egi="(?P<rel>[^"]+)">.*?</details>', re.S)
s2, n = pat.subn(block, s)
io.open(INDEX, 'w', encoding='utf-8').write(s2)
print('embedded %d full sources' % n)
