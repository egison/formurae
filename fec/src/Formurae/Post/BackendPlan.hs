-- | Effect validation for FEIR opaque storage requests.
--
-- FEIR v1 no longer ships any operation with a materializing storage
-- effect: the conservative Laplace--Beltrami and the metric
-- codifferential lower through the prelude macro pipeline before FEIR is
-- produced, so the remaining opaque operations (coordinate-wide, ordered,
-- and grid-whole derivatives, and explicit resampling) are all pure-local
-- and lower inline during compilation.  This module keeps the
-- program-level validation that used to precede request planning:
-- initializers may not carry storage effects, occurrences of one semantic
-- key must agree on their payloads, and any operation the manifest marks
-- as materializing is rejected.
module Formurae.Post.BackendPlan
  ( BackendPlanError(..)
  , planBackendEffects
  ) where

import Data.List (nub, sortOn)

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import qualified Formurae.FEIR.PrimitiveManifest as Manifest
import Formurae.FEIR.Syntax

data BackendPlanError
  = EffectfulRequestInInitializer OpId SemanticKey OriginId
  | ConflictingOpaqueSemanticKey SemanticKey
  | ConflictingOpaqueRequestGroup RequestGroupId
  | UnsupportedEffectfulOperation OpId SemanticKey OriginId
  deriving (Eq, Ord, Show)

data RequestOccurrence = RequestOccurrence
  { occurrenceOpaque :: OpaqueDiscrete
  , occurrenceOrigin :: OriginId
  , occurrenceOrigins :: [OriginId]
  } deriving (Eq, Ord, Show)

planBackendEffects :: FEProgram -> Either BackendPlanError ()
planBackendEffects program = do
  rejectInitializerEffects program
  uniqueOccurrences <- deduplicateSemanticKeys
    (concatMap collectActionOccurrences (feProgramStepActions program))
  rejectGroupConflicts uniqueOccurrences
  rejectMaterializingEffects uniqueOccurrences

rejectMaterializingEffects
    :: [RequestOccurrence]
    -> Either BackendPlanError ()
rejectMaterializingEffects occurrences =
  case
    [ occurrence
    | occurrence <- occurrences
    , isMaterializingOperation
        (opaqueDiscreteOpId (occurrenceOpaque occurrence))
    ] of
    occurrence : _ ->
      let opaque = occurrenceOpaque occurrence
      in Left (UnsupportedEffectfulOperation
          (opaqueDiscreteOpId opaque)
          (opaqueDiscreteSemanticKey opaque)
          (occurrenceOrigin occurrence))
    [] -> Right ()

rejectInitializerEffects :: FEProgram -> Either BackendPlanError ()
rejectInitializerEffects program =
  case
    [ occurrence
    | initializer <- feProgramInitializers program
    , occurrence <- collectInitializerOccurrences initializer
    , isMaterializingOperation
        (opaqueDiscreteOpId (occurrenceOpaque occurrence))
    ] of
    occurrence : _ ->
      let opaque = occurrenceOpaque occurrence
      in Left (EffectfulRequestInInitializer
          (opaqueDiscreteOpId opaque)
          (opaqueDiscreteSemanticKey opaque)
          (occurrenceOrigin occurrence))
    [] -> Right ()

deduplicateSemanticKeys
    :: [RequestOccurrence]
    -> Either BackendPlanError [RequestOccurrence]
deduplicateSemanticKeys = go [] []
  where
    go _seen kept [] = Right (reverse kept)
    go seen kept (occurrence : rest) =
      let opaque = occurrenceOpaque occurrence
          key = opaqueDiscreteSemanticKey opaque
      in case lookup key seen of
          Nothing -> go ((key, opaque) : seen) (occurrence : kept) rest
          Just first
            | sameSemanticPayload first opaque ->
                go seen (mergeOrigins key occurrence kept) rest
            | otherwise -> Left (ConflictingOpaqueSemanticKey key)

    mergeOrigins key occurrence = map merge
      where
        merge keptOccurrence
          | opaqueDiscreteSemanticKey (occurrenceOpaque keptOccurrence) == key =
              keptOccurrence
                { occurrenceOrigins = nub
                    (occurrenceOrigins keptOccurrence
                      ++ occurrenceOrigins occurrence)
                }
          | otherwise = keptOccurrence

rejectGroupConflicts
    :: [RequestOccurrence]
    -> Either BackendPlanError ()
rejectGroupConflicts occurrences = mapM_ checkGroup groups
  where
    groups = nub (map
      (opaqueDiscreteRequestGroup . occurrenceOpaque) occurrences)
    checkGroup group =
      case
        [ occurrenceOpaque occurrence
        | occurrence <- occurrences
        , opaqueDiscreteRequestGroup (occurrenceOpaque occurrence) == group
        ] of
        [] -> Right ()
        first : rest
          | all (sameRequestGroupPayload first) rest -> Right ()
          | otherwise -> Left (ConflictingOpaqueRequestGroup group)

collectInitializerOccurrences :: FEInitializer -> [RequestOccurrence]
collectInitializerOccurrences initializer =
  case initializer of
    AnalyticInitializer equation -> collectTensorOccurrences
      (feEquationOrigin equation) (feEquationRhs equation)
    RawInitializer _ _ _ -> []

collectActionOccurrences :: FEAction -> [RequestOccurrence]
collectActionOccurrences action =
  case action of
    BindValue _ value origin -> collectValueOccurrences origin value
    Materialize _ value origin -> collectValueOccurrences origin value
    UpdateField equation -> collectTensorOccurrences
      (feEquationOrigin equation) (feEquationRhs equation)

collectValueOccurrences :: OriginId -> FEValue -> [RequestOccurrence]
collectValueOccurrences origin value =
  case value of
    ScalarValue scalar -> collectScalarOccurrences origin scalar
    TensorValue tensor -> collectTensorOccurrences origin tensor

collectTensorOccurrences :: OriginId -> TensorNF -> [RequestOccurrence]
collectTensorOccurrences origin tensor = concatMap
  (collectScalarOccurrences origin . snd) (tensorNFComponents tensor)

collectScalarOccurrences :: OriginId -> ScalarNF -> [RequestOccurrence]
collectScalarOccurrences origin scalar =
  case scalar of
    Exact _ _ -> []
    NamedConstant _ -> []
    Parameter _ -> []
    Coordinate _ -> []
    Add terms -> concatMap recurse terms
    Mul factors -> concatMap recurse factors
    Div numerator denominator -> recurse numerator ++ recurse denominator
    Pow base exponentValue -> recurse base ++ recurse exponentValue
    Intrinsic _ arguments -> concatMap recurse arguments
    AnalyticCall _ arguments -> concatMap recurse arguments
    Select predicate yes no ->
      collectPredicateOccurrences origin predicate ++ recurse yes ++ recurse no
    FieldJet _ -> []
    OpaqueDiscrete opaque ->
      RequestOccurrence opaque origin [origin]
      : concatMap (collectValueOccurrences origin)
          (opaqueDiscreteOperands opaque)
    Ref _ -> []
  where
    recurse = collectScalarOccurrences origin

collectPredicateOccurrences :: OriginId -> PredicateNF -> [RequestOccurrence]
collectPredicateOccurrences origin predicate =
  case predicate of
    BoolExact _ -> []
    Compare _ lhs rhs -> recurse lhs ++ recurse rhs
    Not body -> collectPredicateOccurrences origin body
    And bodies -> concatMap (collectPredicateOccurrences origin) bodies
    Or bodies -> concatMap (collectPredicateOccurrences origin) bodies
  where
    recurse = collectScalarOccurrences origin

sameSemanticPayload :: OpaqueDiscrete -> OpaqueDiscrete -> Bool
sameSemanticPayload lhs rhs =
  opaqueDiscreteOpId lhs == opaqueDiscreteOpId rhs
  && opaqueDiscreteResultBasis lhs == opaqueDiscreteResultBasis rhs
  && opaqueDiscreteOperands lhs == opaqueDiscreteOperands rhs
  && sortedAttributes lhs == sortedAttributes rhs

sameRequestGroupPayload :: OpaqueDiscrete -> OpaqueDiscrete -> Bool
sameRequestGroupPayload lhs rhs =
  opaqueDiscreteOpId lhs == opaqueDiscreteOpId rhs
  && opaqueDiscreteOperands lhs == opaqueDiscreteOperands rhs
  && sortedAttributes lhs == sortedAttributes rhs

sortedAttributes :: OpaqueDiscrete -> [Attribute]
sortedAttributes = sortOn attributeId . opaqueDiscreteAttributes

isMaterializingOperation :: OpId -> Bool
isMaterializingOperation opId =
  case Primitives.lookupPrimitiveSignature opId of
    Just signature ->
      case Manifest.primitiveSignatureEffect signature of
        Manifest.NeedsMaterialization _ -> True
        Manifest.PureLocal -> False
    Nothing -> False
