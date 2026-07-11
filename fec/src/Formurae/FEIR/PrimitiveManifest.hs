-- | The shared primitive manifest covers operation identity, value
-- categories, placement, effects, and commutation.  Operation-specific
-- attribute names and schemas remain in each versioned encoder/Post contract;
-- they are deliberately not inferred from this common table.
module Formurae.FEIR.PrimitiveManifest
  ( PrimitiveManifest(..)
  , PrimitiveSignature(..)
  , ValueCategory(..)
  , PlacementRule(..)
  , PrimitiveEffect(..)
  , AuxiliaryRole(..)
  , Commutation(..)
  , PrimitiveManifestError(..)
  , parsePrimitiveManifest
  , loadPrimitiveManifest
  , validatePrimitiveManifest
  , canonicalPrimitiveManifest
  , primitiveManifestFingerprint
  , primitiveManifestId
  ) where

import Control.Monad (foldM)
import Data.Char (isAlphaNum)
import Data.List (group, nub, sort, sortOn)
import Text.Read (readMaybe)

import Formurae.FEIR.Fingerprint (sha256Utf8)
import Formurae.FEIR.SExpr
  ( SExpr(..)
  , SExprError
  , parseSExpr
  , renderSExpr
  )
import Formurae.FEIR.Syntax
  ( Fingerprint(..)
  , PrimitiveManifestId(..)
  , VersionedOpId(..)
  )

data PrimitiveManifest = PrimitiveManifest
  { primitiveManifestSchemaVersion :: Int
  , primitiveManifestSignatures :: [PrimitiveSignature]
  } deriving (Eq, Ord, Show)

data PrimitiveSignature = PrimitiveSignature
  { primitiveSignatureOpId :: VersionedOpId
  , primitiveSignatureOpName :: String
  , primitiveSignatureOpVersion :: Int
  , primitiveSignatureInputs :: [ValueCategory]
  , primitiveSignatureOutput :: ValueCategory
  , primitiveSignaturePlacement :: PlacementRule
  , primitiveSignatureEffect :: PrimitiveEffect
  , primitiveSignatureCommutation :: Commutation
  } deriving (Eq, Ord, Show)

data ValueCategory
  = ScalarCategory
  | TensorCategory
  | FormCategory
  | AnyCategory
  deriving (Eq, Ord, Show)

data PlacementRule
  = PreserveSourcePlacement
  | DerivativeTargetPlacement
  | ExplicitTargetPlacement
  | ConservativeCellPlacement
  | DualAdjointPlacement
  deriving (Eq, Ord, Show)

data PrimitiveEffect
  = PureLocal
  | NeedsMaterialization [AuxiliaryRole]
  deriving (Eq, Ord, Show)

data AuxiliaryRole
  = CoefficientRole
  | VolumeRole
  | FluxRole
  | ResultRole
  | IntermediateRole
  deriving (Eq, Ord, Show)

data Commutation
  = Ordered
  | DeclaredCommutative
  deriving (Eq, Ord, Show)

data PrimitiveManifestError
  = PrimitiveManifestSyntaxError SExprError
  | PrimitiveManifestValidationError String
  deriving (Eq, Ord, Show)

data ManifestAccumulator = ManifestAccumulator
  { accumulatedSchemaVersion :: Maybe Int
  , accumulatedSignatures :: [PrimitiveSignature]
  }

data SignatureAccumulator = SignatureAccumulator
  { accumulatedOp :: Maybe (VersionedOpId, String, Int)
  , accumulatedInputs :: Maybe [ValueCategory]
  , accumulatedOutput :: Maybe ValueCategory
  , accumulatedPlacement :: Maybe PlacementRule
  , accumulatedEffect :: Maybe PrimitiveEffect
  , accumulatedCommutation :: Maybe Commutation
  }

parsePrimitiveManifest :: String -> Either PrimitiveManifestError PrimitiveManifest
parsePrimitiveManifest source = do
  expression <- mapLeft PrimitiveManifestSyntaxError (parseSExpr source)
  manifest <- parseManifestExpression expression
  validatePrimitiveManifest manifest

loadPrimitiveManifest
  :: FilePath -> IO (Either PrimitiveManifestError PrimitiveManifest)
loadPrimitiveManifest path = parsePrimitiveManifest <$> readFile path

parseManifestExpression
  :: SExpr -> Either PrimitiveManifestError PrimitiveManifest
parseManifestExpression (List (Atom "primitive-manifest" : entries)) = do
  accumulator <- foldM parseManifestEntry emptyManifestAccumulator entries
  schemaVersion <- requireField "schema" (accumulatedSchemaVersion accumulator)
  pure PrimitiveManifest
    { primitiveManifestSchemaVersion = schemaVersion
    , primitiveManifestSignatures = reverse (accumulatedSignatures accumulator)
    }
parseManifestExpression expression =
  validationError
    ("expected primitive-manifest root, got " ++ renderSExpr expression)

emptyManifestAccumulator :: ManifestAccumulator
emptyManifestAccumulator = ManifestAccumulator Nothing []

parseManifestEntry
  :: ManifestAccumulator -> SExpr
  -> Either PrimitiveManifestError ManifestAccumulator
parseManifestEntry accumulator (List (Atom "schema" : fields)) = do
  version <- parseSchema fields
  version' <- setOnce "schema" version (accumulatedSchemaVersion accumulator)
  pure accumulator { accumulatedSchemaVersion = version' }
parseManifestEntry accumulator (List (Atom "primitive" : fields)) = do
  signature <- parsePrimitiveSignature fields
  pure accumulator
    { accumulatedSignatures = signature : accumulatedSignatures accumulator }
parseManifestEntry _ expression =
  validationError
    ("unknown primitive-manifest entry " ++ renderSExpr expression)

parseSchema :: [SExpr] -> Either PrimitiveManifestError Int
parseSchema [Atom "formurae-feir-primitives", Atom versionText] = do
  version <- parseCanonicalInt "schema version" versionText
  if version == 1
    then pure version
    else validationError
      ("unsupported primitive manifest schema version " ++ show version)
parseSchema fields =
  validationError
    ("invalid schema declaration " ++ renderSExpr (List (Atom "schema" : fields)))

parsePrimitiveSignature
  :: [SExpr] -> Either PrimitiveManifestError PrimitiveSignature
parsePrimitiveSignature fields = do
  accumulator <- foldM parseSignatureField emptySignatureAccumulator fields
  (opId, opName, opVersion) <- requireField "op" (accumulatedOp accumulator)
  inputs <- requireField "inputs" (accumulatedInputs accumulator)
  output <- requireField "output" (accumulatedOutput accumulator)
  placement <- requireField "placement" (accumulatedPlacement accumulator)
  effect <- requireField "effects" (accumulatedEffect accumulator)
  commutation <- requireField "commutation" (accumulatedCommutation accumulator)
  pure PrimitiveSignature
    { primitiveSignatureOpId = opId
    , primitiveSignatureOpName = opName
    , primitiveSignatureOpVersion = opVersion
    , primitiveSignatureInputs = inputs
    , primitiveSignatureOutput = output
    , primitiveSignaturePlacement = placement
    , primitiveSignatureEffect = effect
    , primitiveSignatureCommutation = commutation
    }

emptySignatureAccumulator :: SignatureAccumulator
emptySignatureAccumulator = SignatureAccumulator
  { accumulatedOp = Nothing
  , accumulatedInputs = Nothing
  , accumulatedOutput = Nothing
  , accumulatedPlacement = Nothing
  , accumulatedEffect = Nothing
  , accumulatedCommutation = Nothing
  }

parseSignatureField
  :: SignatureAccumulator -> SExpr
  -> Either PrimitiveManifestError SignatureAccumulator
parseSignatureField accumulator (List (Atom "op" : fields)) = do
  value <- parseOp fields
  value' <- setOnce "op" value (accumulatedOp accumulator)
  pure accumulator { accumulatedOp = value' }
parseSignatureField accumulator (List (Atom "inputs" : fields)) = do
  value <- parseInputs fields
  value' <- setOnce "inputs" value (accumulatedInputs accumulator)
  pure accumulator { accumulatedInputs = value' }
parseSignatureField accumulator (List (Atom "output" : fields)) = do
  value <- parseOutput fields
  value' <- setOnce "output" value (accumulatedOutput accumulator)
  pure accumulator { accumulatedOutput = value' }
parseSignatureField accumulator (List (Atom "placement" : fields)) = do
  value <- parsePlacement fields
  value' <- setOnce "placement" value (accumulatedPlacement accumulator)
  pure accumulator { accumulatedPlacement = value' }
parseSignatureField accumulator (List (Atom "effects" : fields)) = do
  value <- parseEffect fields
  value' <- setOnce "effects" value (accumulatedEffect accumulator)
  pure accumulator { accumulatedEffect = value' }
parseSignatureField accumulator (List (Atom "commutation" : fields)) = do
  value <- parseCommutation fields
  value' <- setOnce "commutation" value (accumulatedCommutation accumulator)
  pure accumulator { accumulatedCommutation = value' }
parseSignatureField _ expression =
  validationError ("unknown primitive field " ++ renderSExpr expression)

parseOp
  :: [SExpr]
  -> Either PrimitiveManifestError (VersionedOpId, String, Int)
parseOp [Atom name, Atom versionText] = do
  if validOpName name
    then pure ()
    else validationError ("invalid primitive operation name " ++ show name)
  version <- parseCanonicalInt "primitive operation version" versionText
  if version > 0
    then pure
      ( VersionedOpId (name ++ "@" ++ show version)
      , name
      , version
      )
    else validationError "primitive operation version must be positive"
parseOp fields =
  validationError ("invalid op field " ++ renderSExpr (List (Atom "op" : fields)))

validOpName :: String -> Bool
validOpName [] = False
validOpName name =
  all (\character -> isAlphaNum character || character `elem` ".-_") name
  && '@' `notElem` name

parseInputs :: [SExpr] -> Either PrimitiveManifestError [ValueCategory]
parseInputs [] = validationError "primitive inputs must not be empty"
parseInputs fields = mapM parseCategory fields

parseOutput :: [SExpr] -> Either PrimitiveManifestError ValueCategory
parseOutput [field] = parseCategory field
parseOutput fields =
  validationError
    ("primitive output needs one category, got " ++ renderSExpr (List fields))

parseCategory :: SExpr -> Either PrimitiveManifestError ValueCategory
parseCategory (Atom "scalar") = pure ScalarCategory
parseCategory (Atom "tensor") = pure TensorCategory
parseCategory (Atom "form") = pure FormCategory
parseCategory (Atom "any") = pure AnyCategory
parseCategory expression =
  validationError ("unknown value category " ++ renderSExpr expression)

parsePlacement :: [SExpr] -> Either PrimitiveManifestError PlacementRule
parsePlacement [Atom "preserve-source"] = pure PreserveSourcePlacement
parsePlacement [Atom "derivative-target"] = pure DerivativeTargetPlacement
parsePlacement [Atom "explicit-target"] = pure ExplicitTargetPlacement
parsePlacement [Atom "conservative-cell"] = pure ConservativeCellPlacement
parsePlacement [Atom "dual-adjoint"] = pure DualAdjointPlacement
parsePlacement fields =
  validationError
    ("unknown or invalid placement rule " ++ renderSExpr (List fields))

parseEffect :: [SExpr] -> Either PrimitiveManifestError PrimitiveEffect
parseEffect [Atom "pure-local"] = pure PureLocal
parseEffect (Atom "needs-materialization" : roleExpressions) = do
  roles <- mapM parseAuxiliaryRole roleExpressions
  if null roles
    then validationError "needs-materialization requires at least one role"
    else if length roles /= length (nub roles)
      then validationError "duplicate auxiliary role"
      else pure (NeedsMaterialization roles)
parseEffect fields =
  validationError
    ("unknown or invalid primitive effect " ++ renderSExpr (List fields))

parseAuxiliaryRole :: SExpr -> Either PrimitiveManifestError AuxiliaryRole
parseAuxiliaryRole (Atom "coefficient") = pure CoefficientRole
parseAuxiliaryRole (Atom "volume") = pure VolumeRole
parseAuxiliaryRole (Atom "flux") = pure FluxRole
parseAuxiliaryRole (Atom "result") = pure ResultRole
parseAuxiliaryRole (Atom "intermediate") = pure IntermediateRole
parseAuxiliaryRole expression =
  validationError ("unknown auxiliary role " ++ renderSExpr expression)

parseCommutation :: [SExpr] -> Either PrimitiveManifestError Commutation
parseCommutation [Atom "ordered"] = pure Ordered
parseCommutation [Atom "declared-commutative"] = pure DeclaredCommutative
parseCommutation fields =
  validationError
    ("unknown or invalid commutation rule " ++ renderSExpr (List fields))

validatePrimitiveManifest
  :: PrimitiveManifest -> Either PrimitiveManifestError PrimitiveManifest
validatePrimitiveManifest manifest
  | primitiveManifestSchemaVersion manifest /= 1 =
      validationError "primitive manifest schema version must be 1"
  | null signatures =
      validationError "primitive manifest must contain at least one primitive"
  | otherwise =
      case duplicateOpIds of
        duplicateOpId : _ ->
          validationError
            ("duplicate primitive operation " ++ show duplicateOpId)
        [] -> do
          normalized <- mapM validateSignature signatures
          pure manifest
            { primitiveManifestSignatures =
                sortOn primitiveSignatureOpId normalized
            }
  where
    signatures = primitiveManifestSignatures manifest
    duplicateOpIds = duplicates (map primitiveSignatureOpId signatures)

validateSignature
  :: PrimitiveSignature -> Either PrimitiveManifestError PrimitiveSignature
validateSignature signature
  | not (validOpName (primitiveSignatureOpName signature)) =
      validationError "invalid primitive operation name"
  | primitiveSignatureOpVersion signature <= 0 =
      validationError "primitive operation version must be positive"
  | primitiveSignatureOpId signature /= expectedOpId =
      validationError "primitive operation ID does not match its name and version"
  | null (primitiveSignatureInputs signature) =
      validationError "primitive inputs must not be empty"
  | not (placementAcceptsOutput
      (primitiveSignaturePlacement signature)
      (primitiveSignatureOutput signature)) =
      validationError
        "primitive placement rule is incompatible with its output category"
  | otherwise =
      case primitiveSignatureEffect signature of
        PureLocal -> pure signature
        NeedsMaterialization roles
          | null roles ->
              validationError "needs-materialization requires at least one role"
          | length roles /= length (nub roles) ->
              validationError "duplicate auxiliary role"
          | otherwise ->
              pure signature
                { primitiveSignatureEffect =
                    NeedsMaterialization (sortOn auxiliaryRoleAtom roles)
                }
  where
    expectedOpId = VersionedOpId
      (primitiveSignatureOpName signature
       ++ "@" ++ show (primitiveSignatureOpVersion signature))

placementAcceptsOutput :: PlacementRule -> ValueCategory -> Bool
placementAcceptsOutput PreserveSourcePlacement _ = True
placementAcceptsOutput DerivativeTargetPlacement ScalarCategory = True
placementAcceptsOutput ExplicitTargetPlacement ScalarCategory = True
placementAcceptsOutput ConservativeCellPlacement ScalarCategory = True
placementAcceptsOutput DualAdjointPlacement FormCategory = True
placementAcceptsOutput _ _ = False

canonicalPrimitiveManifest :: PrimitiveManifest -> SExpr
canonicalPrimitiveManifest manifest =
  List
    ( Atom "primitive-manifest"
    : List
        [ Atom "schema"
        , Atom "formurae-feir-primitives"
        , Atom (show (primitiveManifestSchemaVersion manifest))
        ]
    : map signatureSExpr
        (sortOn primitiveSignatureOpId
          (primitiveManifestSignatures manifest))
    )

signatureSExpr :: PrimitiveSignature -> SExpr
signatureSExpr signature =
  List
    [ Atom "primitive"
    , List
        [ Atom "op"
        , Atom (primitiveSignatureOpName signature)
        , Atom (show (primitiveSignatureOpVersion signature))
        ]
    , List
        (Atom "inputs" : map (Atom . categoryAtom)
          (primitiveSignatureInputs signature))
    , List [Atom "output", Atom (categoryAtom (primitiveSignatureOutput signature))]
    , List
        [ Atom "placement"
        , Atom (placementAtom (primitiveSignaturePlacement signature))
        ]
    , effectSExpr (primitiveSignatureEffect signature)
    , List
        [ Atom "commutation"
        , Atom (commutationAtom (primitiveSignatureCommutation signature))
        ]
    ]

effectSExpr :: PrimitiveEffect -> SExpr
effectSExpr PureLocal = List [Atom "effects", Atom "pure-local"]
effectSExpr (NeedsMaterialization roles) =
  List
    ( Atom "effects" : Atom "needs-materialization"
    : map (Atom . auxiliaryRoleAtom) (sortOn auxiliaryRoleAtom roles)
    )

categoryAtom :: ValueCategory -> String
categoryAtom ScalarCategory = "scalar"
categoryAtom TensorCategory = "tensor"
categoryAtom FormCategory = "form"
categoryAtom AnyCategory = "any"

placementAtom :: PlacementRule -> String
placementAtom PreserveSourcePlacement = "preserve-source"
placementAtom DerivativeTargetPlacement = "derivative-target"
placementAtom ExplicitTargetPlacement = "explicit-target"
placementAtom ConservativeCellPlacement = "conservative-cell"
placementAtom DualAdjointPlacement = "dual-adjoint"

auxiliaryRoleAtom :: AuxiliaryRole -> String
auxiliaryRoleAtom CoefficientRole = "coefficient"
auxiliaryRoleAtom VolumeRole = "volume"
auxiliaryRoleAtom FluxRole = "flux"
auxiliaryRoleAtom ResultRole = "result"
auxiliaryRoleAtom IntermediateRole = "intermediate"

commutationAtom :: Commutation -> String
commutationAtom Ordered = "ordered"
commutationAtom DeclaredCommutative = "declared-commutative"

primitiveManifestFingerprint :: PrimitiveManifest -> Fingerprint
primitiveManifestFingerprint manifest =
  Fingerprint
    ("sha256:"
     ++ sha256Utf8 (renderSExpr (canonicalPrimitiveManifest manifest)))

primitiveManifestId :: PrimitiveManifest -> PrimitiveManifestId
primitiveManifestId manifest =
  case primitiveManifestFingerprint manifest of
    Fingerprint fingerprint -> PrimitiveManifestId fingerprint

parseCanonicalInt
  :: String -> String -> Either PrimitiveManifestError Int
parseCanonicalInt label source =
  case readMaybe source of
    Just value
      | show value == source -> pure value
      | otherwise -> validationError (label ++ " is not canonical")
    Nothing -> validationError (label ++ " is not an integer")

setOnce
  :: String -> a -> Maybe a -> Either PrimitiveManifestError (Maybe a)
setOnce _ value Nothing = pure (Just value)
setOnce label _ (Just _) = validationError ("duplicate " ++ label ++ " field")

requireField
  :: String -> Maybe a -> Either PrimitiveManifestError a
requireField _ (Just value) = pure value
requireField label Nothing = validationError ("missing " ++ label ++ " field")

duplicates :: Ord a => [a] -> [a]
duplicates values =
  [ first
  | duplicateGroup@(first : _) <- group (sort values)
  , length duplicateGroup > 1
  ]

validationError :: String -> Either PrimitiveManifestError a
validationError = Left . PrimitiveManifestValidationError

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft function value =
  case value of
    Left err -> Left (function err)
    Right result -> Right result
