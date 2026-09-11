-- Appended to the same model by verify.py, with seed = 2 (a smooth
-- defect-free tensor field, see run.py) and one time step.  The continuum
-- covariant Laplacian of the initial tensor is differentiated analytically
-- in Egison, independently of the grid stencils, from the same definitions.
-- The last two terms of each bracket are -Γ^m_{kk} ∇_m Q with the summation
-- over m written out, so that the result keeps the rank two of Q.
def smoothX unused = cos (2 * θ + 4 * φ)
def smoothY unused = sin (2 * θ + 4 * φ)
def smooth unused = withSymbols [i, j] ([| [| smoothX 0 / (2 * g_1_1), smoothY 0 / (2 * volume) |], [| smoothY 0 / (2 * volume), 0 - smoothX 0 / (2 * g_2_2) |] |]~i~j)
def analyticTheta unused = withSymbols [i, j, l] (∂/∂ (smooth 0)~i~j θ + (gamma 0)~i_1_l . (smooth 0)~l~j + (gamma 0)~j_1_l . (smooth 0)~i~l)
def analyticPhi unused = withSymbols [i, j, l] (∂/∂ (smooth 0)~i~j φ + (gamma 0)~i_2_l . (smooth 0)~l~j + (gamma 0)~j_2_l . (smooth 0)~i~l)
def analyticLaplacian unused = withSymbols [i, j, m] (g~1~1 * (∂/∂ (analyticTheta 0)~i~j θ + (gamma 0)~i_1_m . (analyticTheta 0)~m~j + (gamma 0)~j_1_m . (analyticTheta 0)~i~m - (gamma 0)~1_1_1 * (analyticTheta 0)~i~j - (gamma 0)~2_1_1 * (analyticPhi 0)~i~j) + g~2~2 * (∂/∂ (analyticPhi 0)~i~j φ + (gamma 0)~i_2_m . (analyticPhi 0)~m~j + (gamma 0)~j_2_m . (analyticPhi 0)~i~m - (gamma 0)~1_2_2 * (analyticTheta 0)~i~j - (gamma 0)~2_2_2 * (analyticPhi 0)~i~j))
def weightedNorm2 T~a~b = withSymbols [i, j, k, l] (GD_i_k . GD_j_l . T~i~j . T~k~l)
field exact~i~j @ collocated
field error : scalar @ collocated
field reference : scalar @ collocated
---
  exact~i~j := analyticLaplacian 0
  error := 0
  reference := 0
---
  exact' = exact
  local rate~i~j @ collocated = (Q'~i~j - Q~i~j) / (dt * L) - exact~i~j
  error' = cell * J * weightedNorm2 rate
  reference' = cell * J * weightedNorm2 exact
