# -*- coding: utf-8 -*-
# fec.py -- the .fe compiler (v1).
#
# Translates the surface DSL (.fe) into the embedded DSL v0 form: an
# Egison program over lib/fmrgen.egi + lib/fmrdsl.egi.  All semantics
# (tensor index notation, differential forms, CAS expansion, the .fmr
# printer) live on the Egison side; this file is a thin, line-oriented
# translator.  Usage:
#
#   python3 tools/fec.py model.fe > model.egi
#   egison -l lib/fmrgen.egi -l lib/fmrdsl.egi model.egi > model.fmr
#
# .fe grammar (v1):
#   -- comment                      (kept out of the output)
#   param NAME = RAW                Formura parameter (double :: NAME = RAW)
#   extern NAME                     extern function :: NAME
#   raw LINE                        verbatim Formura helper line
#   field NAME : scalar             one grid field
#   field NAME : vector             3 components (NAMEx,NAMEy,NAMEz)
#   field NAME : 1-form | 2-form    3 components placed by form degree (DEC)
#   init:
#     COMP = RAW                    raw Formura initializer
#     NAME := EXPR                  CAS initializer (printed via fmrInit)
#   step:
#     let N_i = EXPR                named tensor expression (inlined)
#     let N = EXPR                  named scalar expression (inlined)
#     local N = EXPR                intermediate grid field (emitted line)
#     N' = EXPR                     scalar / k-form update
#     N'_i = EXPR                   vector update (index equation)
#   assert-dd-zero NAME'            gate generation on d(d NAME') == 0
#
# Inside EXPR, Egison syntax passes through unchanged; the translator
# only resolves DSL-level names:
#   - a vector (or tensor let) name used as an operator argument gets _#
#   - a k-form name used with d / codF2 becomes its component list, and
#     d is resolved by degree (d on 1-form = dF1, etc.)
#   - a bare k-form name in a form equation becomes its K-th component
#   - X' refers to the updated field (Formura's primed array)
import io, os, re, sys

VEC_OPS = ['curl', 'divg', 'dGrad']          # take a whole tensor: arg gets _#
FORM_D = {0: 'dF0', 1: 'dF1', 2: 'dF2'}      # exterior derivative by degree


def die(msg, ln=None):
    where = ' (line %d)' % ln if ln else ''
    sys.stderr.write('fec: error%s: %s\n' % (where, msg))
    sys.exit(1)


class Model(object):
    def __init__(self):
        self.name = ''
        self.params = []          # (name, raw)
        self.helpers = []         # raw lines
        self.fields = []          # (name, kind) kind in scalar|vector|1-form|2-form
        self.inits = []           # ('raw', comp, raw) | ('cas', name, expr)
        self.steps = []           # ('let', name, indexed?, expr) | ('local', ...)
                                  # | ('eq', name, indexed?, expr)
        self.ddgate = None        # primed form name for the d.d==0 gate

    def kind(self, nm):
        for n, k in self.fields:
            if n == nm:
                return k
        return None


def parse(path):
    m = Model()
    m.name = os.path.splitext(os.path.basename(path))[0]
    section = None
    for ln, line in enumerate(io.open(path, encoding='utf-8'), 1):
        line = line.rstrip('\n')
        code = re.sub(r'--.*$', '', line).rstrip()
        if not code.strip():
            continue
        s = code.strip()
        if s == 'init:':
            section = 'init'; continue
        if s == 'step:':
            section = 'step'; continue
        if not code.startswith(' '):
            section = None
        if section is None:
            if re.match(r'param\s+', s):
                mm = re.match(r'param\s+(\w+)\s*=\s*(.+)$', s) or die('bad param', ln)
                m.params.append((mm.group(1), mm.group(2).strip()))
            elif re.match(r'extern\s+', s):
                m.helpers.append('extern function :: ' + s.split(None, 1)[1].strip())
            elif re.match(r'raw\s', code.strip() + ' '):
                m.helpers.append(s[4:] if len(s) > 4 else '')
            elif s == 'raw':
                m.helpers.append('')
            elif re.match(r'field\s+', s):
                mm = re.match(r"field\s+([A-Za-z]\w*)\s*:\s*(scalar|vector|1-form|2-form)$", s) \
                     or die('bad field decl: %s' % s, ln)
                m.fields.append((mm.group(1), mm.group(2)))
            elif re.match(r'assert-dd-zero\s+', s):
                m.ddgate = s.split(None, 1)[1].strip()
            elif s.startswith('dim '):
                if s.split()[1] != '3':
                    die('v1 supports dim 3 only', ln)
            else:
                die('unrecognized: %s' % s, ln)
        elif section == 'init':
            mm = re.match(r"([A-Za-z]\w*'?)\s*:=\s*(.+)$", s)
            if mm:
                m.inits.append(('cas', mm.group(1), mm.group(2).strip()))
                continue
            mm = re.match(r"([A-Za-z]\w*)\s*=\s*(.+)$", s) or die('bad init: %s' % s, ln)
            m.inits.append(('raw', mm.group(1), mm.group(2).strip()))
        elif section == 'step':
            mm = re.match(r"let\s+([A-Za-z][A-Za-z0-9]*)(_i)?\s*=\s*(.+)$", s)
            if mm:
                m.steps.append(('let', mm.group(1), bool(mm.group(2)), mm.group(3).strip()))
                continue
            mm = re.match(r"local\s+([A-Za-z][A-Za-z0-9]*)\s*=\s*(.+)$", s)
            if mm:
                m.steps.append(('local', mm.group(1), False, mm.group(2).strip()))
                continue
            mm = re.match(r"([A-Za-z][A-Za-z0-9]*)'(_i)?\s*=\s*(.+)$", s) or die('bad step eq: %s' % s, ln)
            m.steps.append(('eq', mm.group(1), bool(mm.group(2)), mm.group(3).strip()))
    return m


def primed_refs(m):
    """field names X whose updated value X' is referenced in some RHS"""
    refs = set()
    for _, tgt, _, expr in m.steps:
        for mm in re.finditer(r"([A-Za-z]\w*)'", expr):
            nm = mm.group(1)
            if m.kind(nm):
                refs.add(nm)
    return refs


def rewrite(m, expr, lets, K=None):
    """resolve DSL names inside an Egison expression"""
    e = expr
    forms = {n: k for n, k in m.fields if k.endswith('-form')}
    vecs = {n for n, k in m.fields if k == 'vector'}

    # exterior derivative sugar and form operators: the argument becomes
    # the component list (Xs, or XsN for a primed reference)
    def form_list(nm, primed):
        return nm + ('sN' if primed else 's')

    def op_repl(mm):
        op, nm, pr = mm.group(1), mm.group(2), mm.group(3) == "'"
        if nm in forms:
            deg = int(forms[nm][0])
            fn = FORM_D[deg] if op == 'd' else op
            return '@L{%s %s}@' % (fn, form_list(nm, pr))
        if op == 'd':
            return mm.group(0)
        if nm in vecs or nm in lets:
            return '%s %s%s_#' % (op, nm, "'" if pr else '')
        return mm.group(0)
    e = re.sub(r"\b(d|codF2|dF0|dF1|dF2|curl|divg|dGrad)\s+([A-Za-z]\w*)(')?", op_repl, e)

    # bare form names -> K-th component; op results -> nth K (...)
    if K is not None:
        def comp_repl(mm):
            nm, pr = mm.group(1), mm.group(2) == "'"
            if nm in forms:
                return "%s%s_%d" % (nm, "'" if pr else '', K)
            return mm.group(0)
        e = re.sub(r"(?<![\w@{])([A-Za-z]\w*)(')?(?![\w'(])", comp_repl, e)
        e = re.sub(r'@L\{([^}]*)\}@', r'nth %d (\1)' % K, e)
    else:
        e = re.sub(r'@L\{([^}]*)\}@', r'(\1)', e)
    return e


def emit(m):
    out = []
    w = out.append
    w('--')
    w('-- GENERATED by tools/fec.py from %s.fe -- edit the .fe, not this file' % m.name)
    w('--')
    w('')
    if m.params:
        w('declare symbol ' + ', '.join(p for p, _ in m.params))
        w('')
    prims = primed_refs(m)
    lets = {nm for kindw, nm, _, _ in m.steps if kindw == 'let'}

    # field declarations
    for nm, k in m.fields:
        if k == 'scalar':
            w('def %s := function (x, y, z)' % nm)
        else:
            w('def %s_i := generateTensor (\\[i] -> function (x, y, z)) [3]' % nm)
            if k.endswith('-form'):
                w('def %ss : [MathValue] := [%s_1, %s_2, %s_3]' % (nm, nm, nm, nm))
    for nm in sorted(prims):
        k = m.kind(nm)
        if k == 'scalar':
            w("def %s' := function (x, y, z)" % nm)
        else:
            w("def %s'_i := generateTensor (\\[i] -> function (x, y, z)) [3]" % nm)
            if k.endswith('-form'):
                w("def %ssN : [MathValue] := [%s'_1, %s'_2, %s'_3]" % (nm, nm, nm, nm))
    # local intermediate fields
    for kindw, nm, _, _ in m.steps:
        if kindw == 'local':
            w('def %s := function (x, y, z)' % nm)
    w('')

    # lets and step equations
    step_items = []      # egison exprs contributing [String]
    for kindw, nm, indexed, expr in m.steps:
        kfld = m.kind(nm)
        if kindw == 'let':
            if indexed:
                w('def %s_i := withSymbols [i] %s' % (nm, rewrite(m, expr, lets)))
            else:
                w('def %s := %s' % (nm, rewrite(m, expr, lets)))
        elif kindw == 'local':
            step_items.append('[fmrEq "%s" (%s)]' % (nm, rewrite(m, expr, lets)))
        elif indexed:                                   # vector equation
            w('def feq%s_i := withSymbols [i] %s' % (nm, rewrite(m, expr, lets)))
            step_items.append('vecEqs "%s" feq%s_1 feq%s_2 feq%s_3' % (nm, nm, nm, nm))
        elif kfld and kfld.endswith('-form'):           # form equation
            cs = ' '.join('(%s)' % rewrite(m, expr, lets, K) for K in (1, 2, 3))
            step_items.append('vecEqs "%s" %s' % (nm, cs))
        else:                                           # scalar equation
            step_items.append('scalarEq "%s" (%s)' % (nm, rewrite(m, expr, lets)))
    if m.ddgate:
        base = m.ddgate.rstrip("'")
        w('def feDD := dF2 (dF1 %ssN)' % base)
    w('')

    # declarative model description
    w('def feParams := [%s]' % ', '.join('("%s", "%s")' % p for p in m.params))
    if m.helpers:
        w('def feHelpers :=')
        for i, h in enumerate(m.helpers):
            w(('  [ ' if i == 0 else '  , ') + '"%s"' % h.replace('\\', '\\\\').replace('"', '\\"'))
        w('  ]')
    else:
        w('def feHelpers : [String] := []')
    kindnum = {'scalar': 0, 'vector': 1, '1-form': 1, '2-form': 1}
    w('def feFlds : [(String, Integer)] := [%s]'
      % ', '.join('("%s", %d)' % (n, kindnum[k]) for n, k in m.fields))
    w('def feInits :=')
    for i, it in enumerate(m.inits):
        pre = '  [ ' if i == 0 else '  , '
        if it[0] == 'raw':
            w(pre + '"  %s[i,j,k] = %s"' % (it[1], it[2].replace('"', '\\"')))
        else:
            w(pre + 'fmrInit "%s" (%s)' % (it[1], rewrite(m, it[2], lets)))
    w('  ]')
    w('def feSteps := %s' % ' ++ '.join(step_items))
    w('')
    if m.ddgate:
        w('def main (args: [String]) : IO () :=')
        w('  if feDD = 0')
        w('    then print (emitModel feParams feHelpers feFlds feInits feSteps)')
        w('    else print "# ERROR: d . d /= 0 on this grid -- refusing to generate"')
    else:
        w('def main (args: [String]) : IO () := print (emitModel feParams feHelpers feFlds feInits feSteps)')
    return '\n'.join(out) + '\n'


def main():
    if len(sys.argv) != 2:
        sys.stderr.write('usage: fec.py model.fe > model.egi\n')
        sys.exit(2)
    sys.stdout.write(emit(parse(sys.argv[1])))


if __name__ == '__main__':
    main()
