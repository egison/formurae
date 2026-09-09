"""Measure decay, Taylor rolls and traveling azimuthal waves in saved results."""
import json

import numpy as np

from taylor_couette import WORK, RESULTS, sha


def analyze(name):
    path = WORK/name/'frames.npz'
    data = np.load(path)
    velocity = data['velocity']
    times = data['time']
    report = json.loads((RESULTS/f'taylor-couette-{name}.json').read_text())
    observations = report['observations']
    late = times >= .75*times[-1]
    secondary = np.array([r['secondary_rms'] for r in observations])
    nonaxis = np.array([r['nonaxisymmetric_rms'] for r in observations])
    final = velocity[-1].astype(float)
    radius = data['radius']
    analytic = (48/radius-3*radius)/7
    deviation = float(np.max(np.abs(final[1].mean(axis=(1, 2))-analytic)))
    nt, nz = final.shape[-2:]
    spectrum = np.fft.rfft(final, axis=2)
    power = (np.abs(spectrum)**2*radius[None, :, None, None]).sum(axis=(0, 1, 3))
    power[1:-1] *= 2
    result = dict(reynolds=report['reynolds'], grid=report['grid'],
                  secondary_final=float(secondary[-1]), nonaxisymmetric_final=float(nonaxis[-1]),
                  secondary_late_mean=float(secondary[late].mean()),
                  nonaxisymmetric_late_mean=float(nonaxis[late].mean()),
                  secondary_growth_factor=float(secondary[-1]/secondary[0]),
                  nonaxisymmetric_late_decay_rate=(float(np.polyfit(times[late], np.log(np.maximum(nonaxis[late], 1e-60)), 1)[0])
                    if np.max(nonaxis[late]) > 1e-10 else None),
                  mean_azimuthal_profile_departure_from_couette=deviation,
                  max_divergence=max(r['max_divergence'] for r in observations),
                  max_courant=max(r['courant'] for r in observations),
                  highest_third_azimuthal_band_fraction_of_nonaxisymmetric_energy=(float(power[nt//3:].sum()/power[1:].sum())
                    if nonaxis[-1] > 1e-10 else None),
                  frames_sha256=sha(path))
    if nonaxis[-1] > 1e-3:
        mid = velocity[:, 0, final.shape[1]//2].astype(float)
        modes = np.fft.fft2(mid, axes=(1, 2))
        strength = np.mean(np.abs(modes[late])**2, axis=0)
        strength[0] = 0
        strength[nt//2:] = 0
        strength[:, 0] = 0
        m, n = map(int, np.unravel_index(strength.argmax(), strength.shape))
        phase = np.unwrap(np.angle(modes[:, m, n]))
        slope, intercept = np.polyfit(times[late], phase[late], 1)
        # A coherent moving wave has a steadily advancing Fourier phase.
        residual = float(np.sqrt(np.mean((phase[late]-slope*times[late]-intercept)**2)))
        phase_speed = float(-slope/m)
        signed_n = n if n <= nz//2 else n-nz
        axial_modes = np.fft.fft(mid[-1], axis=1)
        phase_theta = np.unwrap(np.angle(axial_modes[:, abs(signed_n)]))
        displacement = -phase_theta*float(data['length'])/(2*np.pi*abs(signed_n))
        result['traveling_wave'] = dict(azimuthal_mode=m, axial_mode=signed_n,
                                        angular_speed=phase_speed,
                                        fraction_of_inner_cylinder_angular_speed=3*phase_speed,
                                        phase_fit_rms_radians=residual,
                                        axial_displacement_peak_to_peak=float(np.ptp(displacement)))
    return result


def main():
    cases = {name:analyze(name) for name in ('re60', 're150', 're600')}
    low, mid, high = [cases[name] for name in ('re60', 're150', 're600')]
    checks = dict(
        low_speed_disturbance_decays=low['secondary_growth_factor'] < 1e-3,
        low_speed_matches_couette=low['mean_azimuthal_profile_departure_from_couette'] < 1e-3,
        middle_speed_forms_nearly_axisymmetric_rolls=mid['secondary_growth_factor'] > 10
            and mid['nonaxisymmetric_final'] < .1*mid['secondary_final']
            and mid['nonaxisymmetric_late_decay_rate'] < 0,
        high_speed_breaks_azimuthal_symmetry=high['nonaxisymmetric_final'] > 1e-3,
        high_speed_wave_moves='traveling_wave' in high and abs(high['traveling_wave']['angular_speed']) > .01
                              and high['traveling_wave']['phase_fit_rms_radians'] < .5,
        volume_preserved=all(c['max_divergence'] < 1e-8 for c in cases.values()))
    result = dict(passed=all(checks.values()), checks=checks, cases=cases, analyzer_sha256=sha(__file__))
    if (WORK/'pilot600/frames.npz').exists():
        coarse = analyze('pilot600')
        result['coarser_grid'] = coarse
        result['relative_change_under_refinement'] = {
            key:abs(high[key]-coarse[key])/abs(high[key])
            for key in ('secondary_late_mean', 'nonaxisymmetric_late_mean')}
    if (WORK/'refined600/frames.npz').exists():
        finer = analyze('refined600')
        result['finer_grid'] = finer
        result['relative_change_to_finer_grid'] = {
            key:abs(high[key]-finer[key])/abs(finer[key])
            for key in ('secondary_late_mean', 'nonaxisymmetric_late_mean')}
        checks['finer_grid_confirms_growing_traveling_wave'] = (
            finer['nonaxisymmetric_final'] > 1e-3
            and finer['nonaxisymmetric_late_decay_rate'] > 0
            and abs(finer['traveling_wave']['angular_speed']) > .01
            and finer['traveling_wave']['phase_fit_rms_radians'] < .5)
        result['passed'] = all(checks.values())
    (RESULTS/'taylor-couette-comparison.json').write_text(json.dumps(result, indent=2, allow_nan=False)+'\n')
    print(json.dumps(result, indent=2))
    if not result['passed']:
        raise SystemExit('The simulation did not pass the flow-pattern checks')


if __name__ == '__main__':
    main()
