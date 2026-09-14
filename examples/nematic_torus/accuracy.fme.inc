-- Appended to the same model by verify.py, with seed = 2 (a smooth
-- defect-free tensor field, see run.py) and one time step.  The continuum
-- covariant Laplacian of the initial tensor is differentiated analytically
-- in Egison, independently of the grid stencils, from the same definitions.
-- The last two terms of each bracket are -Γ^m_{kk} ∇_m Q with the summation
-- over m written out, so that the result keeps the rank two of Q.
def smoothX = cos (2 * θ + 4 * φ)
def smoothY = sin (2 * θ + 4 * φ)
def smooth = withSymbols [i, j] ([| [| smoothX / (2 * g_1_1), smoothY / (2 * volume) |], [| smoothY / (2 * volume), 0 - smoothX / (2 * g_2_2) |] |]~i~j)
def analyticTheta = withSymbols [i, j, l] (∂/∂ smooth~i~j θ + gamma~i_1_l . smooth~l~j + gamma~j_1_l . smooth~i~l)
def analyticPhi = withSymbols [i, j, l] (∂/∂ smooth~i~j φ + gamma~i_2_l . smooth~l~j + gamma~j_2_l . smooth~i~l)
def analyticLaplacian = withSymbols [i, j, m] (g~1~1 * (∂/∂ analyticTheta~i~j θ + gamma~i_1_m . analyticTheta~m~j + gamma~j_1_m . analyticTheta~i~m - gamma~1_1_1 * analyticTheta~i~j - gamma~2_1_1 * analyticPhi~i~j) + g~2~2 * (∂/∂ analyticPhi~i~j φ + gamma~i_2_m . analyticPhi~m~j + gamma~j_2_m . analyticPhi~i~m - gamma~1_2_2 * analyticTheta~i~j - gamma~2_2_2 * analyticPhi~i~j))
def weightedNorm2 T~a~b = withSymbols [i, j, k, l] (GD_i_k . GD_j_l . T~i~j . T~k~l)
static field exact~i~j @ collocated := analyticLaplacian
field error : scalar @ collocated
field reference : scalar @ collocated
---
  error := 0
  reference := 0
---
  local rate~i~j @ collocated = (Q'~i~j - Q~i~j) / (dt * L) - exact~i~j
  error' = cell * J * weightedNorm2 rate
  reference' = cell * J * weightedNorm2 exact
