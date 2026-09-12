-- Appended to the model by verify.py for the accuracy tests.  A torsional
-- mode of the shell is an exact solution at every time: the velocity points
-- along the longitude, its angular part is the associated Legendre function
-- P_3^1 (whose zeros at colatitude arctan 2 and π - arctan 2 are the cones),
-- its radial profile f(R) is the combination of the spherical Bessel
-- functions of order 3 that vanishes on both spheres, and kappa is the first
-- root of that condition at the outer radius (found by bisection; verify.py
-- recomputes it).  With g = 5 cos²θ - 1 the chart components are
-- v^φ = f g cos(κt)/r, σ^{rφ} = (f' - f/r) g sin(κt)/(κr), and
-- σ^{θφ} = f g' sin(κt)/(κr³); the twisted chart shears the longitude with
-- the radius, which adds σ^{φφ} = -2 twist σ^{rφ}.  The initial state
-- (substituted by verify.py) is the mode at time 0; exactV/exactS hold the
-- mode at the final time T.
param kappa = 3.9225199109537163
param amplitude = -0.06071560645180932
param T = 1.0
def besselJ2 x = (3 / x^2 - 1) * sin x / x - 3 * cos x / x^2
def besselY2 x = 0 - (3 / x^2 - 1) * cos x / x - 3 * sin x / x^2
def besselJ3 x = (15 / x^3 - 6 / x) * sin x / x - (15 / x^2 - 1) * cos x / x
def besselY3 x = 0 - (15 / x^3 - 6 / x) * cos x / x - (15 / x^2 - 1) * sin x / x
def profile unused = (besselJ3 (kappa * r) * besselY3 kappa - besselY3 (kappa * r) * besselJ3 kappa) / amplitude
def profileDerivative unused = kappa * ((besselJ2 (kappa * r) - 4 * besselJ3 (kappa * r) / (kappa * r)) * besselY3 kappa - (besselY2 (kappa * r) - 4 * besselY3 (kappa * r) / (kappa * r)) * besselJ3 kappa) / amplitude
def angular unused = 5 * (cos θ)^2 - 1
def modeShear tau = (profileDerivative 0 - profile 0 / r) * angular 0 * sin (kappa * tau) / (kappa * r)
def modeTilt tau = 0 - 10 * profile 0 * cos θ * sin θ * sin (kappa * tau) / (kappa * r^3)
def modeV tau = [| 0, 0, profile 0 * angular 0 * cos (kappa * tau) / r |]~i
def modeS tau = [| [| 0, 0, modeShear tau |], [| 0, 0, modeTilt tau |], [| modeShear tau, modeTilt tau, 0 - 2 * twist * modeShear tau |] |]~i~j
field exactV~i @ collocated
field exactS{~i~j} @ collocated
field err : scalar @ collocated
field ref : scalar @ collocated
---
  exactV~i := modeV T
  exactS~i~j := modeS T
  err := 0
  ref := 0
---
  exactV' = exactV
  exactS' = exactS
  local dv~i @ collocated = v'~i - exactV~i
  local ds~i~j @ collocated = σ'~i~j - exactS~i~j
  err' = weight 0 * cell * volume * (norm2 dv + stressNorm ds)
  ref' = weight 0 * cell * volume * (norm2 exactV + stressNorm exactS)
