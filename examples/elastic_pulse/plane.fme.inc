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
def cp = sqrt ((λ + 2 * μ) / ρ0)
def cs = sqrt (μ / ρ0)
def tilt = shear * wavenumber * cos (wavenumber * y)
def isP = if wave < 1.5 then 1 else 0
def isS = if wave < 1.5 then 0 else 1
def epsP tau = kappa * amplitude * cos (kappa * (physical - cp * tau))
def epsS tau = kappa * amplitude * cos (kappa * (physical - cs * tau))
def planeV tau = [| isP * (0 - cp * epsP tau) + isS * tilt * cs * epsS tau, isS * (0 - cs * epsS tau), 0 |]~i
def planeS tau = [| [| isP * (λ + 2 * μ + λ * tilt^2) * epsP tau - isS * 2 * μ * tilt * epsS tau, isS * μ * epsS tau - isP * λ * tilt * epsP tau, 0 |], [| isS * μ * epsS tau - isP * λ * tilt * epsP tau, isP * λ * epsP tau, 0 |], [| 0, 0, isP * λ * epsP tau |] |]~i~j
static field exactV~i @ collocated := planeV T
static field exactS{~i~j} @ collocated := planeS T
field err : scalar @ collocated
field ref : scalar @ collocated
---
  err := 0
  ref := 0
---
  local dv~i @ collocated = v'~i - exactV~i
  local ds~i~j @ collocated = σ'~i~j - exactS~i~j
  err' = cell * volume * (norm2 dv + stressNorm ds)
  ref' = cell * volume * (norm2 exactV + stressNorm exactS)
