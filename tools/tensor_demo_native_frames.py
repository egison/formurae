"""Read native simulation output for visualization; no fluid time integration."""
import numpy as np


def load_couette_frame(folder, report, index):
    values = np.load(folder / f'frame-{index:04d}.npy', allow_pickle=False)
    names = report['outputs']
    assert values.shape == (len(names), report['radial'] + 1, report['angular'])
    assert np.isfinite(values).all()
    def components(*fields):
        return values[[names.index(name) for name in fields]]
    return dict(v=components('velocity_up1', 'velocity_up2'),
                conformation=components('conformation_up1_up1',
                                        'conformation_up1_up2',
                                        'conformation_up2_up2'),
                psi=values[names.index('psi')], time=report['frames'][index]['time'])
