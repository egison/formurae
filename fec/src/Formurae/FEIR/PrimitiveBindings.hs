-- This file is generated from spec/feir-primitives.sexp.
-- Run tools/generate-feir-primitives.hs; do not edit it directly.
module Formurae.FEIR.PrimitiveBindings
  ( primitiveManifestId
  , primitiveManifest
  , primitiveSignatures
  , primitiveOperationIds
  , lookupPrimitiveSignature
  , derivativeCoordinateWideOpId
  , derivativeGridWholeOpId
  , derivativeOrderedOpId
  , derivativeSbpStaggeredOpId
  , resampleExplicitOpId
  ) where

import Formurae.FEIR.PrimitiveManifest
  ( Commutation(..)
  , PlacementRule(..)
  , PrimitiveEffect(..)
  , PrimitiveManifest(..)
  , PrimitiveSignature(..)
  , ValueCategory(..)
  )
import Formurae.FEIR.Syntax
  ( PrimitiveManifestId(..)
  , OpId(..)
  )

primitiveManifestId :: PrimitiveManifestId
primitiveManifestId = PrimitiveManifestId "sha256:f85bce3e5dc32e8c096ceafaf0c44e2a0d5a4bef2b0b5454b3afae63588666bd"

primitiveManifest :: PrimitiveManifest
primitiveManifest = PrimitiveManifest primitiveSignatures

primitiveSignatures :: [PrimitiveSignature]
primitiveSignatures =
  [ PrimitiveSignature
      { primitiveSignatureOpId = derivativeCoordinateWideOpId
      , primitiveSignatureOpName = "derivative.coordinate-wide"
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = derivativeGridWholeOpId
      , primitiveSignatureOpName = "derivative.grid-whole"
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = derivativeOrderedOpId
      , primitiveSignatureOpName = "derivative.ordered"
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = derivativeSbpStaggeredOpId
      , primitiveSignatureOpName = "derivative.sbp-staggered"
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = resampleExplicitOpId
      , primitiveSignatureOpName = "resample.explicit"
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = ExplicitTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  ]

primitiveOperationIds :: [OpId]
primitiveOperationIds =
  [ derivativeCoordinateWideOpId
  , derivativeGridWholeOpId
  , derivativeOrderedOpId
  , derivativeSbpStaggeredOpId
  , resampleExplicitOpId
  ]

lookupPrimitiveSignature :: OpId -> Maybe PrimitiveSignature
lookupPrimitiveSignature operationId = lookup operationId
  [ (primitiveSignatureOpId signature, signature)
  | signature <- primitiveSignatures
  ]

derivativeCoordinateWideOpId :: OpId
derivativeCoordinateWideOpId = OpId "derivative.coordinate-wide"

derivativeGridWholeOpId :: OpId
derivativeGridWholeOpId = OpId "derivative.grid-whole"

derivativeOrderedOpId :: OpId
derivativeOrderedOpId = OpId "derivative.ordered"

derivativeSbpStaggeredOpId :: OpId
derivativeSbpStaggeredOpId = OpId "derivative.sbp-staggered"

resampleExplicitOpId :: OpId
resampleExplicitOpId = OpId "resample.explicit"
