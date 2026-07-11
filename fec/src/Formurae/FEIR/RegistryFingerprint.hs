-- | Canonical identity for the logical registry shared by pre-fec and
-- post-fec.  Runtime equations, normalized geometry expressions, the
-- discretization profile, and provenance are deliberately outside this
-- identity: changing any of those must not make stable logical IDs belong to
-- a different registry.
module Formurae.FEIR.RegistryFingerprint
  ( computeRegistryId
  , registryIdMatches
  , registryFingerprintPayload
  ) where

import Formurae.FEIR.Codec (encodeFEProgram)
import Formurae.FEIR.Fingerprint (sha256Utf8)
import Formurae.FEIR.SExpr (SExpr(..), renderSExpr)
import Formurae.FEIR.Syntax

computeRegistryId :: FEProgram -> RegistryId
computeRegistryId program =
  RegistryId ("sha256:" ++ sha256Utf8
    (renderSExpr (registryFingerprintPayload program)))

registryIdMatches :: FEProgram -> Bool
registryIdMatches program =
  feProgramRegistryId program == computeRegistryId program

registryFingerprintPayload :: FEProgram -> SExpr
registryFingerprintPayload program = List
  [ Atom "logical-registry"
  , List [Atom "schema", Atom "formurae-logical-registry", Atom "1"]
  , named "mode" (programField "mode")
  , named "dimension" (programField "dimension")
  , named "axes" (programField "axes")
  , named "geometry" (geometryIdentity (feProgramGeometry program))
  , named "parameters" (programField "parameters")
  , named "functions" (programField "functions")
  , named "fields" (programField "fields")
  , named "raw-helpers" (programField "raw-helpers")
  ]
  where
    encoded = encodeFEProgram program
    programField name =
      case encoded of
        List (_tag : _version : fields) ->
          case [value | List [Atom actual, value] <- fields, actual == name] of
            [value] -> value
            _ -> error ("registryFingerprintPayload: missing FEIR field " ++ name)
        _ -> error "registryFingerprintPayload: invalid FEIR encoder result"

named :: String -> SExpr -> SExpr
named name value = List [Atom name, value]

geometryIdentity :: GeometryDecl -> SExpr
geometryIdentity geometry = List
  [ Atom "geometry-registry"
  , named "id" (numericId geometryId)
  , named "source-name" (optionalString (geometryDeclSourceName geometry))
  , named "origin" (optionalNumericId unwrapOrigin
      (geometryDeclOrigin geometry))
  , named "kind" (Atom (geometryKindTag (geometryDeclKind geometry)))
  ]
  where
    GeometryId geometryId = geometryDeclId geometry
    unwrapOrigin (OriginId value) = value

geometryKindTag :: GeometryKind -> String
geometryKindTag EuclideanGeometry = "euclidean"
geometryKindTag (OrthogonalScaleGeometry _ _) = "orthogonal-scale"
geometryKindTag (EmbeddedOrthogonalGeometry _ _) = "embedded-orthogonal"

numericId :: Int -> SExpr
numericId = Atom . show

optionalString :: Maybe String -> SExpr
optionalString Nothing = List [Atom "none"]
optionalString (Just value) = List [Atom "some", StringAtom value]

optionalNumericId :: (a -> Int) -> Maybe a -> SExpr
optionalNumericId _ Nothing = List [Atom "none"]
optionalNumericId unwrap (Just value) =
  List [Atom "some", numericId (unwrap value)]
