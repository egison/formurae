-- Appended to the same model by verify.py, with stimulus=0, reaction=0.
-- The initial profile is 1 + sin(theta)*cos(phi). Differentiate its
-- continuum flux analytically in Egison, independently of the grid stencil.
def analyticTheta X = withSymbols [j] (volume * (diffusivity (angle + twist * sin θ))~1~j . [| cos θ * cos φ, -sin θ * sin φ |]_j)
def analyticPhi X = withSymbols [j] (volume * (diffusivity (angle + twist * sin θ))~2~j . [| cos θ * cos φ, -sin θ * sin φ |]_j)
def exactRate X = ((∂/∂ (analyticTheta 0) θ) + (∂/∂ (analyticPhi 0) φ)) / volume
field exact : scalar @ primal
field error : scalar @ primal
field reference : scalar @ primal
---
  exact := exactRate 0
  error := 0
  reference := 0
---
  exact' = exact
  error' = cell * J * ((u' - u) / dt - exact)^2
  reference' = cell * J * exact^2
