# Changelog for Formurae

## Unreleased

- Accept Egison's index application on parenthesized expressions, `(f x)~i_j`,
  in init, step and def expressions, including numeric component indices.
- Add `metric tensor [[...], [...]]` and `metric volume EXPR` for metrics
  declared by their components (non-orthogonal coordinates).
- Add the nematic liquid crystal on a torus and transformation optics examples,
  and the sheared-chart version of the excitable torus example.

## 0.1.0.0

- Introduce the `formurae` Cabal package name.
- Provide the `formurae`, `formurae-pre`, and `formurae-post` executables.
- Install the versioned Egison normalization libraries with the package.
- Support a clone-and-`cabal install` distribution workflow.
