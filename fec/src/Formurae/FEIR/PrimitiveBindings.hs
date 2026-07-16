-- This file is generated from spec/feir-primitives-v1.sexp.
-- Run tools/generate-feir-primitives.hs; do not edit it directly.
module Formurae.FEIR.PrimitiveBindings
  ( primitiveManifestV1Id
  , primitiveManifestV1
  , primitiveSignaturesV1
  , primitiveOperationIds
  , lookupPrimitiveSignatureV1
  , derivativeCoordinateWideV1OpId
  , derivativeGridWholeV1OpId
  , derivativeOrderedV1OpId
  , resampleExplicitV1OpId
  ) where

import Formurae.FEIR.PrimitiveManifest
  ( AuxiliaryRole(..)
  , Commutation(..)
  , PlacementRule(..)
  , PrimitiveEffect(..)
  , PrimitiveManifest(..)
  , PrimitiveSignature(..)
  , ValueCategory(..)
  )
import Formurae.FEIR.Syntax
  ( PrimitiveManifestId(..)
  , VersionedOpId(..)
  )

primitiveManifestV1Id :: PrimitiveManifestId
primitiveManifestV1Id = PrimitiveManifestId "sha256:15edbc55825f7b9ff02836c67d852b46635f34d7b94a0397d750243b555aa9fb"

primitiveManifestV1 :: PrimitiveManifest
primitiveManifestV1 = PrimitiveManifest 1 primitiveSignaturesV1

primitiveSignaturesV1 :: [PrimitiveSignature]
primitiveSignaturesV1 =
  [ PrimitiveSignature
      { primitiveSignatureOpId = derivativeCoordinateWideV1OpId
      , primitiveSignatureOpName = "derivative.coordinate-wide"
      , primitiveSignatureOpVersion = 1
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = derivativeGridWholeV1OpId
      , primitiveSignatureOpName = "derivative.grid-whole"
      , primitiveSignatureOpVersion = 1
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = derivativeOrderedV1OpId
      , primitiveSignatureOpName = "derivative.ordered"
      , primitiveSignatureOpVersion = 1
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = DerivativeTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  , PrimitiveSignature
      { primitiveSignatureOpId = resampleExplicitV1OpId
      , primitiveSignatureOpName = "resample.explicit"
      , primitiveSignatureOpVersion = 1
      , primitiveSignatureInputs = [ScalarCategory]
      , primitiveSignatureOutput = ScalarCategory
      , primitiveSignaturePlacement = ExplicitTargetPlacement
      , primitiveSignatureEffect = PureLocal
      , primitiveSignatureCommutation = Ordered
      }
  ]

primitiveOperationIds :: [VersionedOpId]
primitiveOperationIds =
  [ derivativeCoordinateWideV1OpId
  , derivativeGridWholeV1OpId
  , derivativeOrderedV1OpId
  , resampleExplicitV1OpId
  ]

lookupPrimitiveSignatureV1 :: VersionedOpId -> Maybe PrimitiveSignature
lookupPrimitiveSignatureV1 operationId = lookup operationId
  [ (primitiveSignatureOpId signature, signature)
  | signature <- primitiveSignaturesV1
  ]

derivativeCoordinateWideV1OpId :: VersionedOpId
derivativeCoordinateWideV1OpId = VersionedOpId "derivative.coordinate-wide@1"

derivativeGridWholeV1OpId :: VersionedOpId
derivativeGridWholeV1OpId = VersionedOpId "derivative.grid-whole@1"

derivativeOrderedV1OpId :: VersionedOpId
derivativeOrderedV1OpId = VersionedOpId "derivative.ordered@1"

resampleExplicitV1OpId :: VersionedOpId
resampleExplicitV1OpId = VersionedOpId "resample.explicit@1"
