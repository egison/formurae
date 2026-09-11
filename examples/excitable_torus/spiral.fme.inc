-- Appended to the same model by spiral.py.  A rotating wave (spiral) tip is a
-- phase singularity of the vector (u - ustar, v - vstar): its winding number
-- around a grid plaquette is +1 or -1.  The winding is computed exactly from
-- one-cell shifts built from compact differences (as in the LBM example), and
-- the tip positions are accumulated as sums of sin/cos so that periodic mean
-- angles can be formed from the reductions.
param ustar = 0.0
param vstar = 0.0
param htheta = dtheta
param hphi = dphi
-- The winding is counted on the two triangles (i,j)->(i+1,j)->(i,j+1) and
-- (i,j)->(i-1,j)->(i,j-1), which tile the torus and read only axis neighbours.
def shift c q = q + c * htheta * ∂_θ q + htheta^2 * ∂^2_θ q / 2
def shiftPhi c q = q + c * hphi * ∂_φ q + hphi^2 * ∂^2_φ q / 2
def crossing ax ay bx by = if ay >= 0 && by < 0 && ax * by - bx * ay > 0 then 1 else (if ay < 0 && by >= 0 && ax * by - bx * ay < 0 then -1 else 0)
-- the Ricci scalar of the torus metric (twice the Gaussian curvature) and its theta-derivative, from the same metric
def christoffel unused = withSymbols [i, j, k, l] ((g~i~l . (∂/∂ g_l_k coordinates~j + ∂/∂ g_l_j coordinates~k - ∂/∂ g_j_k coordinates~l)) / 2)
def riemann unused = withSymbols [i, j, k, l, m] (∂/∂ (christoffel 0)~i_j_l coordinates~k - ∂/∂ (christoffel 0)~i_j_k coordinates~l + (christoffel 0)~m_j_l . (christoffel 0)~i_m_k - (christoffel 0)~m_j_k . (christoffel 0)~i_m_l)
-- Egison appends the index of the differentiation variable after the indices of the
-- differentiated tensor, so riemann carries its indices in the order i, j, l, k;
-- the Ricci tensor R_ij = R^m_imj therefore contracts the first index with the fourth.
def ricciTensor unused = withSymbols [i, j, m] (contractWith (+) (riemann 0)~m_i_j_m)
def ricci unused = withSymbols [i, j] (g~i~j . (ricciTensor 0)_i_j)
field winding : scalar @ primal
field tipPlus : scalar @ primal
field tipMinus : scalar @ primal
field plusCos : scalar @ primal
field plusSin : scalar @ primal
field minusCos : scalar @ primal
field minusSin : scalar @ primal
field ricciScalar : scalar @ primal
field ricciSlope : scalar @ primal
field cosT : scalar @ primal
field sinT : scalar @ primal
-- the same curvature in closed form, 2K = 2 cos θ / (r (R + r cos θ)); the run reports the largest difference
field ricciCheck : scalar @ primal
---
  winding := 0
  tipPlus := 0
  tipMinus := 0
  plusCos := 0
  plusSin := 0
  minusCos := 0
  minusSin := 0
  ricciScalar := ricci 0
  ricciSlope := ∂/∂ (ricci 0) θ
  cosT := cos θ
  sinT := sin θ
  ricciCheck := ricci 0 - 2 * cos θ / (r * (R + r * cos θ))
---
  local ax = u - ustar
  local ay = v - vstar
  local pxp = shift 1 ax
  local pyp = shift 1 ay
  local pxm = shift (-1) ax
  local pym = shift (-1) ay
  local qxp = shiftPhi 1 ax
  local qyp = shiftPhi 1 ay
  local qxm = shiftPhi (-1) ax
  local qym = shiftPhi (-1) ay
  winding' = crossing ax ay pxp pyp + crossing pxp pyp qxp qyp + crossing qxp qyp ax ay + crossing ax ay pxm pym + crossing pxm pym qxm qym + crossing qxm qym ax ay
  tipPlus' = if winding' > 0 then winding' else 0
  tipMinus' = if winding' < 0 then 0 - winding' else 0
  plusCos' = if winding' > 0 then winding' * cosT else 0
  plusSin' = if winding' > 0 then winding' * sinT else 0
  minusCos' = if winding' < 0 then 0 - winding' * cosT else 0
  minusSin' = if winding' < 0 then 0 - winding' * sinT else 0
  ricciScalar' = ricciScalar
  ricciSlope' = ricciSlope
  cosT' = cosT
  sinT' = sinT
  ricciCheck' = ricciCheck
