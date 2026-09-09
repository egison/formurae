"""Build and call the Formurae -> Egison -> Formura -> C Taylor--Couette kernel.

The experiment driver owns time integration, pressure projection, and rendering.
The spatial tensor equations in examples/taylor_couette/*.fme own the PDE RHS.
All compiler subprocesses are run serially. Generated products are cached by
source/library/compiler hashes, not by filename or modification time.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'examples/taylor_couette'
WORK = ROOT / '.build/tensor-demos'
RESULTS = SOURCES / 'results'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(args, cwd, log, output=None):
    print(' '.join(map(str, args)), flush=True)
    with Path(log).open('w') as err:
        with (Path(output).open('w') if output else open(os.devnull, 'w')) as out:
            result = subprocess.run(list(map(str, args)), cwd=cwd, stdout=out, stderr=err)
    if result.returncode:
        raise RuntimeError(f'{args[0]} exited {result.returncode}: {Path(log).read_text()[-6000:]}')


def normalize(name):
    WORK.mkdir(parents=True, exist_ok=True)
    source = SOURCES / f'{name}.fme'
    dependencies = [source, *sorted((ROOT/'lib').glob('*.egi')),
                    *sorted((ROOT/'src').rglob('*.hs'))]
    signature = hashlib.sha256(''.join(sha(p) for p in dependencies).encode()).hexdigest()
    stamp = WORK / f'{name}.normalization.json'
    products = [SOURCES/f'{name}.{ext}' for ext in ('egi', 'feir', 'fmr')]
    if stamp.exists() and all(p.exists() for p in products):
        saved = json.loads(stamp.read_text())
        if saved == {'input': signature, 'output': [sha(p) for p in products]}:
            return products[-1]
    egison = subprocess.check_output([ROOT/'tools/prepare_elastic_validation.sh'], text=True).strip()
    run(['cabal', 'run', '-v0', 'formurae-pre', '--', source], ROOT,
        WORK/f'{name}-pre.log', products[0])
    run([ROOT/'tools/run_formurae_normalization.sh', egison, products[0]], ROOT,
        WORK/f'{name}-egison.log', products[1])
    run(['cabal', 'run', '-v0', 'formurae-post', '--', products[1]], ROOT,
        WORK/f'{name}-post.log', products[2])
    stamp.write_text(json.dumps({'input': signature, 'output': [sha(p) for p in products]}))
    return products[-1]


class Kernel:
    def __init__(self, name, shape, spacing, periodic, replacements=None):
        fmr = normalize(name)
        self.shape = tuple(shape)
        self.count = int(np.prod(shape))
        text = fmr.read_text()
        for before, after in (replacements or {}).items():
            assert before in text, before
            text = text.replace(before, after)
        config = dict(name=name, shape=shape, spacing=spacing, periodic=periodic,
                      fmr=hashlib.sha256(text.encode()).hexdigest(), formura=sha(ROOT/'bin/formura'),
                      wrapper_source=sha(__file__))
        key = hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()[:16]
        self.work = WORK / f'{name}-{key}'
        self.work.mkdir(parents=True, exist_ok=True)
        model = self.work / f'{name}.fmr'
        model.write_text(text)
        lengths = [float(n*h) for n, h in zip(shape, spacing)]
        boundaries = ', '.join('periodic' if p else 'fixed 0.0' for p in periodic)
        (self.work/f'{name}.yaml').write_text(
            f'length_per_node: {lengths}\ngrid_per_node: {list(shape)}\n'
            f'mpi_shape: {[1]*len(shape)}\nboundary: [{boundaries}]\n')
        library = self.work / 'kernel.so'
        if not library.exists():
            run([ROOT/'bin/formura', model.name], self.work, self.work/'formura.log')
            header = (self.work/f'{name}.h').read_text()
            self.fields = re.findall(r'double (\w+)\[', header.split('} Formura_Grid_Struct;')[0])
            members = ','.join(f'(double*)formura_data.{f}' for f in self.fields)
            wrapper = f'''#include "{name}.h"
#include <string.h>
static Formura_Navi nav;
void demo_init(void) {{int argc=0;char **argv=NULL;Formura_Init(&argc,&argv,&nav);}}
void demo_initial(double *out) {{
 double *fields[]={{{members}}};
 for(int c=0;c<{len(self.fields)};c++) memcpy(out+c*{self.count},fields[c],{self.count}*sizeof(double));
}}
void demo_apply(const double *in, double *out) {{
 double *fields[]={{{members}}};
 for(int c=0;c<{len(self.fields)};c++) memcpy(fields[c],in+c*{self.count},{self.count}*sizeof(double));
 Formura_Forward(&nav);
 for(int c=0;c<{len(self.fields)};c++) memcpy(out+c*{self.count},fields[c],{self.count}*sizeof(double));
}}
'''
            (self.work/'wrapper.c').write_text(wrapper)
            run(['cc', '-O2', '-std=c11', '-shared', '-fPIC', '-I.', f'-I{ROOT}/mpistub',
                 'wrapper.c', f'{name}.c', '-lm', '-o', library.name], self.work, self.work/'cc.log')
            (self.work/'fields.json').write_text(json.dumps(self.fields))
        self.fields = json.loads((self.work/'fields.json').read_text())
        self.library = ctypes.CDLL(str(library), mode=ctypes.RTLD_LOCAL)
        pointer = np.ctypeslib.ndpointer(dtype=np.float64, flags='C_CONTIGUOUS')
        self.library.demo_apply.argtypes = [pointer, pointer]
        self.library.demo_initial.argtypes = [pointer]
        self.library.demo_init()
        self.record = {**config, 'fields': self.fields,
                       'generated_c_sha256': sha(self.work/f'{name}.c'),
                       'generated_library_sha256': sha(library)}

    def initial(self):
        state = self.empty()
        self.library.demo_initial(state)
        return state

    def empty(self):
        return np.zeros((len(self.fields), *self.shape), dtype=np.float64)

    def apply(self, state):
        state = np.ascontiguousarray(state, dtype=np.float64)
        assert state.shape == (len(self.fields), *self.shape)
        out = np.empty_like(state)
        self.library.demo_apply(state, out)
        return out

    def indices(self, prefix):
        return [i for i, f in enumerate(self.fields) if f.startswith(prefix)]
