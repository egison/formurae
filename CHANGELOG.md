# Changelog for Formurae

## Unreleased

- Recognize fully numeric components of declared tensor locals as scalars,
  while preserving tensor checks for partial and symbolic indexing.
- Simplify the 2D wave example with existing Egison `generateTensor` helpers,
  whole-tensor conditionals, and recomputed density, velocity and fill fraction
  in place of four persistent scalar components.
- Add `index a, b : 9` for component counts independent of spatial dimension,
  including mixed shapes such as `field c_a_i`, contractions, explicit locals,
  and symmetric/antisymmetric matrices. Preserve spatial slot information in
  FEIR so component indices do not change grid placement.
- Accept Egison's index application on parenthesized expressions, `(f x)~i_j`,
  in init, step and def expressions, including numeric component indices.
- Add `metric tensor [[...], [...]]` and `metric volume EXPR` for metrics
  declared by their components (non-orthogonal coordinates).
- Add the nematic liquid crystal on a torus and transformation optics examples,
  and the sheared-chart version of the excitable torus example.
- Let quoted (backquoted) atoms pass through the FEIR encoder: a quote only
  guides the CAS, so init and step expressions may use them.  The
  transformation optics example derives its material tensors from the
  coordinate maps with `∂/∂` and index contraction.

## 0.1.0.0

- Introduce the `formurae` Cabal package name.
- Provide the `formurae`, `formurae-pre`, and `formurae-post` executables.
- Install the versioned Egison normalization libraries with the package.
- Support a clone-and-`cabal install` distribution workflow.
