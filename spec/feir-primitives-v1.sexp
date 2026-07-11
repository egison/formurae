; FEIR v1 discrete primitive manifest.
; This file is the only source of primitive identities and signatures.
(primitive-manifest
  (schema formurae-feir-primitives 1)

  (primitive
    (op derivative.coordinate-wide 1)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op derivative.ordered 1)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op derivative.grid-whole 1)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op resample.explicit 1)
    (inputs scalar)
    (output scalar)
    (placement explicit-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op flux.conservative-divergence 1)
    (inputs tensor)
    (output scalar)
    (placement conservative-cell)
    (effects needs-materialization flux result)
    (commutation declared-commutative))

  (primitive
    (op lb.orthogonal 1)
    (inputs scalar)
    (output scalar)
    (placement conservative-cell)
    (effects needs-materialization coefficient volume flux result)
    (commutation declared-commutative))

  (primitive
    (op operator.materialized 1)
    (inputs any)
    (output any)
    (placement preserve-source)
    (effects needs-materialization intermediate)
    (commutation ordered))

  (primitive
    (op codiff.metric 1)
    (inputs form)
    (output form)
    (placement dual-adjoint)
    (effects needs-materialization coefficient volume flux result)
    (commutation ordered)))
