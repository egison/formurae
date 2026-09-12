-- Appended to the model by verify.py for the accuracy tests.  A plane P wave
-- (wave = 1) or S wave (wave = 2) of wavenumber kappa travels along the
-- physical X direction; it is an exact solution at every time.  The physical
-- velocity and stress are written in the chart's contravariant components:
-- with X = x + shear sin(wavenumber y) and tilt = dX/dy, the chart components
-- are v^x = V_X - tilt V_Y, v^y = V_Y, and sigma transforms with the same
-- Jacobian.  The initial state (substituted by verify.py) is the wave at
-- time 0; exactV/exactS hold the wave at the final time T.
param wave = 1.0
param kappa = 3.141592653589793
param amplitude = 0.01
param T = 1.0
def cp unused = sqrt ((λ + 2 * μ) / ρ0)
def cs unused = sqrt (μ / ρ0)
def tilt unused = shear * wavenumber * cos (wavenumber * y)
def isP unused = if wave < 1.5 then 1 else 0
def isS unused = if wave < 1.5 then 0 else 1
def epsP tau = kappa * amplitude * cos (kappa * (physical 0 - cp 0 * tau))
def epsS tau = kappa * amplitude * cos (kappa * (physical 0 - cs 0 * tau))
def planeV tau = [| isP 0 * (0 - cp 0 * epsP tau) + isS 0 * tilt 0 * cs 0 * epsS tau, isS 0 * (0 - cs 0 * epsS tau), 0 |]~i
def planeS tau = [| [| isP 0 * (λ + 2 * μ + λ * (tilt 0)^2) * epsP tau - isS 0 * 2 * μ * tilt 0 * epsS tau, isS 0 * μ * epsS tau - isP 0 * λ * tilt 0 * epsP tau, 0 |], [| isS 0 * μ * epsS tau - isP 0 * λ * tilt 0 * epsP tau, isP 0 * λ * epsP tau, 0 |], [| 0, 0, isP 0 * λ * epsP tau |] |]~i~j
field exactV~i @ collocated
field exactS{~i~j} @ collocated
field err : scalar @ collocated
field ref : scalar @ collocated
---
  exactV~i := planeV T
  exactS~i~j := planeS T
  err := 0
  ref := 0
---
  exactV' = exactV
  exactS' = exactS
  local dv~i @ collocated = v'~i - exactV~i
  local ds~i~j @ collocated = σ'~i~j - exactS~i~j
  err' = cell * volume * (norm2 dv + stressNorm ds)
  ref' = cell * volume * (norm2 exactV + stressNorm exactS)
