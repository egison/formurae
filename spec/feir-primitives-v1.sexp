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
    (commutation ordered)))
