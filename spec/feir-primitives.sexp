; FEIR discrete primitive manifest.
; This file is the only source of primitive identities and signatures.
(primitive-manifest
  (schema formurae-feir-primitives)

  (primitive
    (op derivative.coordinate-wide)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op derivative.ordered)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op boundary.sbp-trace)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op derivative.grid-whole)
    (inputs scalar)
    (output scalar)
    (placement derivative-target)
    (effects pure-local)
    (commutation ordered))

  (primitive
    (op resample.explicit)
    (inputs scalar)
    (output scalar)
    (placement explicit-target)
    (effects pure-local)
    (commutation ordered)))
