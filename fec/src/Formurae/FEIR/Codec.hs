module Formurae.FEIR.Codec
  ( CodecError(..)
  , encodeFEProgram
  , decodeFEProgram
  , renderFEProgram
  , parseFEProgram
  , computeProfileFingerprint
  , setProfileFingerprint
  , profileFingerprintMatches
  , encodeScalarNF
  , decodeScalarNF
  , encodePredicateNF
  ) where

import Data.List (group, sort, sortOn)
import Numeric.Natural (Natural)
import Text.Read (readMaybe)

import Formurae.FEIR.Fingerprint (sha256Utf8)
import Formurae.FEIR.SExpr
import Formurae.FEIR.Syntax

data CodecError = CodecError
  { codecErrorContext :: String
  , codecErrorMessage :: String
  } deriving (Eq, Ord, Show)

codecError :: String -> String -> Either CodecError a
codecError context message = Left (CodecError context message)

withContext :: String -> Either CodecError a -> Either CodecError a
withContext context result =
  case result of
    Left err -> Left err
      { codecErrorContext = context ++ "/" ++ codecErrorContext err }
    Right value -> Right value

field :: String -> SExpr -> SExpr
field name value = List [Atom name, value]

record :: String -> [(String, SExpr)] -> SExpr
record tag fields = List (Atom tag : map (uncurry field) fields)

decodeRecord :: String -> [String] -> SExpr -> Either CodecError [(String, SExpr)]
decodeRecord expectedTag expectedFields expression =
  case expression of
    List (Atom actualTag : encodedFields)
      | actualTag /= expectedTag ->
          codecError expectedTag ("expected tag " ++ expectedTag ++ ", got " ++ actualTag)
      | otherwise -> do
          fields <- mapM decodeField encodedFields
          let names = map fst fields
              unknown = [name | name <- names, name `notElem` expectedFields]
              missing = [name | name <- expectedFields, name `notElem` names]
              duplicates = duplicateValues names
          case unknown of
            name : _ -> codecError expectedTag ("unknown field: " ++ name)
            [] -> case duplicates of
              name : _ -> codecError expectedTag ("duplicate field: " ++ name)
              [] -> case missing of
                name : _ -> codecError expectedTag ("missing field: " ++ name)
                [] -> Right fields
    List [] -> codecError expectedTag ("expected " ++ expectedTag ++ " record")
    List (_ : _) -> codecError expectedTag ("record tag must be an atom: " ++ renderSExpr expression)
    _ -> codecError expectedTag ("expected record, got " ++ renderSExpr expression)
  where
    decodeField encoded =
      case encoded of
        List [Atom name, value] -> Right (name, value)
        _ -> codecError expectedTag
          ("record field must have the form (name value): " ++ renderSExpr encoded)

required :: String -> [(String, SExpr)] -> Either CodecError SExpr
required name fields =
  case [value | (fieldName, value) <- fields, fieldName == name] of
    [value] -> Right value
    [] -> codecError name "missing field after record validation"
    _ -> codecError name "duplicate field after record validation"

duplicateValues :: Ord a => [a] -> [a]
duplicateValues values =
  [value | duplicates@(value : _) <- group (sort values), length duplicates > 1]

rejectDuplicateKeys :: Ord a => String -> [a] -> Either CodecError ()
rejectDuplicateKeys context keys =
  case duplicateValues keys of
    _ : _ -> codecError context "duplicate association key"
    [] -> Right ()

encodeList :: (a -> SExpr) -> [a] -> SExpr
encodeList encoder = List . map encoder

decodeList :: String -> (SExpr -> Either CodecError a) -> SExpr -> Either CodecError [a]
decodeList context decoder expression =
  case expression of
    List values -> mapM (withContext context . decoder) values
    _ -> codecError context ("expected list, got " ++ renderSExpr expression)

encodeMaybe :: (a -> SExpr) -> Maybe a -> SExpr
encodeMaybe _ Nothing = List [Atom "none"]
encodeMaybe encoder (Just value) = List [Atom "some", encoder value]

decodeMaybe :: String -> (SExpr -> Either CodecError a) -> SExpr -> Either CodecError (Maybe a)
decodeMaybe context decoder expression =
  case expression of
    List [Atom "none"] -> Right Nothing
    List [Atom "some", value] -> Just <$> withContext context (decoder value)
    _ -> codecError context ("expected (none) or (some value), got " ++ renderSExpr expression)

encodeString :: String -> SExpr
encodeString = StringAtom

decodeString :: String -> SExpr -> Either CodecError String
decodeString _ (StringAtom value) = Right value
decodeString context expression =
  codecError context ("expected string, got " ++ renderSExpr expression)

encodeInt :: Int -> SExpr
encodeInt = Atom . show

decodeInt :: String -> SExpr -> Either CodecError Int
decodeInt context expression =
  case expression of
    Atom value ->
      case readMaybe value of
        Just integer -> Right integer
        Nothing -> codecError context ("invalid integer: " ++ value)
    _ -> codecError context ("expected integer atom, got " ++ renderSExpr expression)

encodeInteger :: Integer -> SExpr
encodeInteger = Atom . show

decodeInteger :: String -> SExpr -> Either CodecError Integer
decodeInteger context expression =
  case expression of
    Atom value ->
      case readMaybe value of
        Just integer -> Right integer
        Nothing -> codecError context ("invalid integer: " ++ value)
    _ -> codecError context ("expected integer atom, got " ++ renderSExpr expression)

encodeNatural :: Natural -> SExpr
encodeNatural = Atom . show

decodeNatural :: String -> SExpr -> Either CodecError Natural
decodeNatural context expression =
  case expression of
    Atom value ->
      case readMaybe value of
        Just natural -> Right natural
        Nothing -> codecError context ("invalid natural number: " ++ value)
    _ -> codecError context ("expected natural-number atom, got " ++ renderSExpr expression)

encodeBool :: Bool -> SExpr
encodeBool True = Atom "true"
encodeBool False = Atom "false"

decodeBool :: String -> SExpr -> Either CodecError Bool
decodeBool _ (Atom "true") = Right True
decodeBool _ (Atom "false") = Right False
decodeBool context expression =
  codecError context ("expected true or false, got " ++ renderSExpr expression)

encodeStringId :: String -> SExpr
encodeStringId = StringAtom

decodeStringId :: String -> (String -> a) -> SExpr -> Either CodecError a
decodeStringId context constructor expression = constructor <$> decodeString context expression

encodeNumericId :: Int -> SExpr
encodeNumericId = encodeInt

decodeNumericId :: String -> (Int -> a) -> SExpr -> Either CodecError a
decodeNumericId context constructor expression = constructor <$> decodeInt context expression

encodeModelId :: ModelId -> SExpr
encodeModelId (ModelId value) = encodeStringId value

decodeModelId :: SExpr -> Either CodecError ModelId
decodeModelId = decodeStringId "model-id" ModelId

encodeSourceId :: SourceId -> SExpr
encodeSourceId (SourceId value) = encodeStringId value

decodeSourceId :: SExpr -> Either CodecError SourceId
decodeSourceId = decodeStringId "source-id" SourceId

encodeRegistryId :: RegistryId -> SExpr
encodeRegistryId (RegistryId value) = encodeStringId value

decodeRegistryId :: SExpr -> Either CodecError RegistryId
decodeRegistryId = decodeStringId "registry-id" RegistryId

encodePrimitiveManifestId :: PrimitiveManifestId -> SExpr
encodePrimitiveManifestId (PrimitiveManifestId value) = encodeStringId value

decodePrimitiveManifestId :: SExpr -> Either CodecError PrimitiveManifestId
decodePrimitiveManifestId = decodeStringId "primitive-manifest-id" PrimitiveManifestId

encodeFingerprint :: Fingerprint -> SExpr
encodeFingerprint (Fingerprint value) = encodeStringId value

decodeFingerprint :: SExpr -> Either CodecError Fingerprint
decodeFingerprint = decodeStringId "fingerprint" Fingerprint

encodeAxisId :: AxisId -> SExpr
encodeAxisId (AxisId value) = encodeNumericId value

decodeAxisId :: SExpr -> Either CodecError AxisId
decodeAxisId = decodeNumericId "axis-id" AxisId

encodeParamId :: ParamId -> SExpr
encodeParamId (ParamId value) = encodeNumericId value

decodeParamId :: SExpr -> Either CodecError ParamId
decodeParamId = decodeNumericId "parameter-id" ParamId

encodeFunctionId :: FunctionId -> SExpr
encodeFunctionId (FunctionId value) = encodeNumericId value

decodeFunctionId :: SExpr -> Either CodecError FunctionId
decodeFunctionId = decodeNumericId "function-id" FunctionId

encodeFieldId :: FieldId -> SExpr
encodeFieldId (FieldId value) = encodeNumericId value

decodeFieldId :: SExpr -> Either CodecError FieldId
decodeFieldId = decodeNumericId "field-id" FieldId

encodeGeometryId :: GeometryId -> SExpr
encodeGeometryId (GeometryId value) = encodeNumericId value

decodeGeometryId :: SExpr -> Either CodecError GeometryId
decodeGeometryId = decodeNumericId "geometry-id" GeometryId

encodeRawHelperId :: RawHelperId -> SExpr
encodeRawHelperId (RawHelperId value) = encodeNumericId value

decodeRawHelperId :: SExpr -> Either CodecError RawHelperId
decodeRawHelperId = decodeNumericId "raw-helper-id" RawHelperId

encodeOriginId :: OriginId -> SExpr
encodeOriginId (OriginId value) = encodeNumericId value

decodeOriginId :: SExpr -> Either CodecError OriginId
decodeOriginId = decodeNumericId "origin-id" OriginId

encodeNodeId :: NodeId -> SExpr
encodeNodeId (NodeId value) = encodeNumericId value

decodeNodeId :: SExpr -> Either CodecError NodeId
decodeNodeId = decodeNumericId "node-id" NodeId

encodeEquationId :: EquationId -> SExpr
encodeEquationId (EquationId value) = encodeNumericId value

decodeEquationId :: SExpr -> Either CodecError EquationId
decodeEquationId = decodeNumericId "equation-id" EquationId

encodeOpId :: OpId -> SExpr
encodeOpId (OpId value) = encodeStringId value

decodeOpId :: SExpr -> Either CodecError OpId
decodeOpId = decodeStringId "op-id" OpId

encodeSemanticKey :: SemanticKey -> SExpr
encodeSemanticKey (SemanticKey value) = encodeStringId value

decodeSemanticKey :: SExpr -> Either CodecError SemanticKey
decodeSemanticKey = decodeStringId "semantic-key" SemanticKey

encodeRequestGroupId :: RequestGroupId -> SExpr
encodeRequestGroupId (RequestGroupId value) = encodeStringId value

decodeRequestGroupId :: SExpr -> Either CodecError RequestGroupId
decodeRequestGroupId = decodeStringId "request-group-id" RequestGroupId

encodeAttributeId :: AttributeId -> SExpr
encodeAttributeId (AttributeId value) = encodeStringId value

decodeAttributeId :: SExpr -> Either CodecError AttributeId
decodeAttributeId = decodeStringId "attribute-id" AttributeId

encodePositive :: Positive -> SExpr
encodePositive (Positive value) = encodeInt value

decodePositive :: SExpr -> Either CodecError Positive
decodePositive = fmap Positive . decodeInt "positive"

encodePositiveEven :: PositiveEven -> SExpr
encodePositiveEven (PositiveEven value) = encodeInt value

decodePositiveEven :: SExpr -> Either CodecError PositiveEven
decodePositiveEven = fmap PositiveEven . decodeInt "positive-even"

encodeBasis :: Basis -> SExpr
encodeBasis (Basis indices) = List (Atom "basis" : map encodeInt indices)

decodeBasis :: SExpr -> Either CodecError Basis
decodeBasis expression =
  case expression of
    List (Atom "basis" : indices) -> Basis <$> mapM (decodeInt "basis-index") indices
    _ -> codecError "basis" ("expected (basis ...), got " ++ renderSExpr expression)

-- ------------------------------------------------------------ top-level IO

renderFEProgram :: FEProgram -> String
renderFEProgram = renderSExpr . encodeFEProgram

parseFEProgram :: String -> Either CodecError FEProgram
parseFEProgram source =
  case parseSExpr source of
    Left err -> codecError "sexpr"
      ("line " ++ show (sexprErrorLine err) ++ ", column "
       ++ show (sexprErrorColumn err) ++ ": " ++ sexprErrorMessage err)
    Right expression -> decodeFEProgram expression

encodeFEProgram :: FEProgram -> SExpr
encodeFEProgram program =
  List
    [ Atom "feir"
    , field "model" (encodeModelIdentity (feProgramModel program))
    , field "registry-id" (encodeRegistryId (feProgramRegistryId program))
    , field "primitive-manifest-id"
        (encodePrimitiveManifestId (feProgramPrimitiveManifestId program))
    , field "discretization"
        (encodeDiscretizationProfile (feProgramDiscretization program))
    , field "mode" (encodeMode (feProgramMode program))
    , field "dimension" (encodeInt (feProgramDimension program))
    , field "axes" (encodeList encodeAxisDecl (feProgramAxes program))
    , field "geometry" (encodeGeometryDecl (feProgramGeometry program))
    , field "parameters" (encodeList encodeParameterDecl (feProgramParameters program))
    , field "functions" (encodeList encodeFunctionDecl (feProgramFunctions program))
    , field "fields" (encodeList encodeLogicalFieldDecl (feProgramFields program))
    , field "initializers" (encodeList encodeFEInitializer (feProgramInitializers program))
    , field "step-actions" (encodeList encodeFEAction (feProgramStepActions program))
    , field "raw-helpers" (encodeList encodeRawHelper (feProgramRawHelpers program))
    , field "origins" (encodeOriginTable (feProgramOrigins program))
    , field "provenance" (encodeProvenanceTable (feProgramProvenance program))
    ]

decodeFEProgram :: SExpr -> Either CodecError FEProgram
decodeFEProgram expression =
  case expression of
    List (Atom "feir" : encodedFields) -> do
      fields <- decodeRecordFields "feir" programFieldNames encodedFields
      program <- FEProgram
        <$> (required "model" fields >>= decodeModelIdentity)
        <*> (required "registry-id" fields >>= decodeRegistryId)
        <*> (required "primitive-manifest-id" fields >>= decodePrimitiveManifestId)
        <*> (required "discretization" fields >>= decodeDiscretizationProfile)
        <*> (required "mode" fields >>= decodeMode)
        <*> (required "dimension" fields >>= decodeInt "dimension")
        <*> (required "axes" fields >>= decodeList "axes" decodeAxisDecl)
        <*> (required "geometry" fields >>= decodeGeometryDecl)
        <*> (required "parameters" fields >>= decodeList "parameters" decodeParameterDecl)
        <*> (required "functions" fields >>= decodeList "functions" decodeFunctionDecl)
        <*> (required "fields" fields >>= decodeList "fields" decodeLogicalFieldDecl)
        <*> (required "initializers" fields >>= decodeList "initializers" decodeFEInitializer)
        <*> (required "step-actions" fields >>= decodeList "step-actions" decodeFEAction)
        <*> (required "raw-helpers" fields >>= decodeList "raw-helpers" decodeRawHelper)
        <*> (required "origins" fields >>= decodeOriginTable)
        <*> (required "provenance" fields >>= decodeProvenanceTable)
      verifyProfileFingerprint (feProgramDiscretization program)
      Right program
    List (Atom tag : _) -> codecError "feir" ("unknown top-level tag: " ++ tag)
    _ -> codecError "feir" "expected (feir ...)"
  where
    programFieldNames =
      [ "model", "registry-id", "primitive-manifest-id", "discretization"
      , "mode", "dimension", "axes", "geometry", "parameters", "functions"
      , "fields", "initializers", "step-actions", "raw-helpers", "origins"
      , "provenance"
      ]

decodeRecordFields
  :: String -> [String] -> [SExpr] -> Either CodecError [(String, SExpr)]
decodeRecordFields context expectedFields encodedFields =
  decodeRecord context expectedFields (List (Atom context : encodedFields))

-- --------------------------------------------------------------- identity

encodeSourceIdentity :: SourceIdentity -> SExpr
encodeSourceIdentity identity = record "source-identity"
  [ ("id", encodeSourceId (sourceIdentityId identity))
  , ("path", encodeString (sourceIdentityPath identity))
  ]

decodeSourceIdentity :: SExpr -> Either CodecError SourceIdentity
decodeSourceIdentity expression = do
  fields <- decodeRecord "source-identity" ["id", "path"] expression
  SourceIdentity
    <$> (required "id" fields >>= decodeSourceId)
    <*> (required "path" fields >>= decodeString "source-path")

encodeModelIdentity :: ModelIdentity -> SExpr
encodeModelIdentity identity = record "model-identity"
  [ ("id", encodeModelId (modelIdentityId identity))
  , ("name", encodeString (modelIdentityName identity))
  , ("source", encodeSourceIdentity (modelIdentitySource identity))
  ]

decodeModelIdentity :: SExpr -> Either CodecError ModelIdentity
decodeModelIdentity expression = do
  fields <- decodeRecord "model-identity" ["id", "name", "source"] expression
  ModelIdentity
    <$> (required "id" fields >>= decodeModelId)
    <*> (required "name" fields >>= decodeString "model-name")
    <*> (required "source" fields >>= decodeSourceIdentity)

-- ----------------------------------------------------------------- origin

encodeSourceLocation :: SourceLocation -> SExpr
encodeSourceLocation location = record "source-location"
  [ ("source", encodeSourceId (sourceLocationSource location))
  , ("path", encodeString (sourceLocationPath location))
  , ("line", encodeInt (sourceLocationLine location))
  , ("end-line", encodeInt (sourceLocationEndLine location))
  , ("start-column", encodeInt (sourceLocationStartColumn location))
  , ("end-column", encodeInt (sourceLocationEndColumn location))
  ]

decodeSourceLocation :: SExpr -> Either CodecError SourceLocation
decodeSourceLocation expression = do
  fields <- decodeRecord "source-location"
    ["source", "path", "line", "end-line", "start-column", "end-column"] expression
  SourceLocation
    <$> (required "source" fields >>= decodeSourceId)
    <*> (required "path" fields >>= decodeString "source-path")
    <*> (required "line" fields >>= decodeInt "line")
    <*> (required "end-line" fields >>= decodeInt "end-line")
    <*> (required "start-column" fields >>= decodeInt "start-column")
    <*> (required "end-column" fields >>= decodeInt "end-column")

encodeExpansionFrame :: ExpansionFrame -> SExpr
encodeExpansionFrame frame = record "expansion-frame"
  [ ("name", encodeString (expansionFrameName frame))
  , ("definition", encodeSourceLocation (expansionFrameDefinition frame))
  , ("call", encodeSourceLocation (expansionFrameCall frame))
  ]

decodeExpansionFrame :: SExpr -> Either CodecError ExpansionFrame
decodeExpansionFrame expression = do
  fields <- decodeRecord "expansion-frame" ["name", "definition", "call"] expression
  ExpansionFrame
    <$> (required "name" fields >>= decodeString "expansion-name")
    <*> (required "definition" fields >>= decodeSourceLocation)
    <*> (required "call" fields >>= decodeSourceLocation)

encodeSourceOrigin :: SourceOrigin -> SExpr
encodeSourceOrigin origin = record "source-origin"
  [ ("location", encodeSourceLocation (sourceOriginLocation origin))
  , ("trace", encodeList encodeExpansionFrame (sourceOriginTrace origin))
  ]

decodeSourceOrigin :: SExpr -> Either CodecError SourceOrigin
decodeSourceOrigin expression = do
  fields <- decodeRecord "source-origin" ["location", "trace"] expression
  SourceOrigin
    <$> (required "location" fields >>= decodeSourceLocation)
    <*> (required "trace" fields >>= decodeList "origin-trace" decodeExpansionFrame)

encodeOriginTable :: OriginTable -> SExpr
encodeOriginTable (OriginTable entries) =
  encodeList encodeEntry (sortOn fst entries)
  where
    encodeEntry (originId, origin) = record "origin-entry"
      [("id", encodeOriginId originId), ("origin", encodeSourceOrigin origin)]

decodeOriginTable :: SExpr -> Either CodecError OriginTable
decodeOriginTable expression = do
  entries <- decodeList "origin-table" decodeEntry expression
  rejectDuplicateKeys "origin-table" (map fst entries)
  Right (OriginTable entries)
  where
    decodeEntry encoded = do
      fields <- decodeRecord "origin-entry" ["id", "origin"] encoded
      (,) <$> (required "id" fields >>= decodeOriginId)
          <*> (required "origin" fields >>= decodeSourceOrigin)

encodeProvenanceTable :: ProvenanceTable -> SExpr
encodeProvenanceTable (ProvenanceTable entries) =
  encodeList encodeEntry (sortOn fst entries)
  where
    encodeEntry (nodeId, originIds) = record "provenance-entry"
      [ ("node", encodeNodeId nodeId)
      , ("origins", encodeList encodeOriginId (sort originIds))
      ]

decodeProvenanceTable :: SExpr -> Either CodecError ProvenanceTable
decodeProvenanceTable expression = do
  entries <- decodeList "provenance-table" decodeEntry expression
  rejectDuplicateKeys "provenance-table" (map fst entries)
  mapM_ (rejectDuplicateKeys "provenance-origins" . snd) entries
  Right (ProvenanceTable entries)
  where
    decodeEntry encoded = do
      fields <- decodeRecord "provenance-entry" ["node", "origins"] encoded
      (,) <$> (required "node" fields >>= decodeNodeId)
          <*> (required "origins" fields >>= decodeList "provenance-origins" decodeOriginId)

-- -------------------------------------------------------------- core enums

encodeMode :: Mode -> SExpr
encodeMode CollocatedMode = Atom "collocated"
encodeMode DecMode = Atom "dec"

decodeMode :: SExpr -> Either CodecError Mode
decodeMode (Atom "collocated") = Right CollocatedMode
decodeMode (Atom "dec") = Right DecMode
decodeMode expression = codecError "mode" ("unknown mode: " ++ renderSExpr expression)

encodeGridPolicy :: GridPolicy -> SExpr
encodeGridPolicy CollocatedPolicy = Atom "collocated"
encodeGridPolicy PrimalPolicy = Atom "primal"
encodeGridPolicy DualPolicy = Atom "dual"

decodeGridPolicy :: SExpr -> Either CodecError GridPolicy
decodeGridPolicy (Atom "collocated") = Right CollocatedPolicy
decodeGridPolicy (Atom "primal") = Right PrimalPolicy
decodeGridPolicy (Atom "dual") = Right DualPolicy
decodeGridPolicy expression = codecError "grid-policy"
  ("unknown grid policy: " ++ renderSExpr expression)

encodeVariance :: Variance -> SExpr
encodeVariance VarianceUp = Atom "up"
encodeVariance VarianceDown = Atom "down"

decodeVariance :: SExpr -> Either CodecError Variance
decodeVariance (Atom "up") = Right VarianceUp
decodeVariance (Atom "down") = Right VarianceDown
decodeVariance expression = codecError "variance"
  ("unknown variance: " ++ renderSExpr expression)

encodeLayout :: Layout -> SExpr
encodeLayout ScalarLayout = Atom "scalar"
encodeLayout VectorLayout = Atom "vector"
encodeLayout SymmetricLayout = Atom "symmetric"
encodeLayout AntisymmetricLayout = Atom "antisymmetric"
encodeLayout FullLayout = Atom "full"
encodeLayout FormLayout = Atom "form"

decodeLayout :: SExpr -> Either CodecError Layout
decodeLayout (Atom "scalar") = Right ScalarLayout
decodeLayout (Atom "vector") = Right VectorLayout
decodeLayout (Atom "symmetric") = Right SymmetricLayout
decodeLayout (Atom "antisymmetric") = Right AntisymmetricLayout
decodeLayout (Atom "full") = Right FullLayout
decodeLayout (Atom "form") = Right FormLayout
decodeLayout expression = codecError "layout"
  ("unknown layout: " ++ renderSExpr expression)

encodeLifetime :: Lifetime -> SExpr
encodeLifetime UserStateLifetime = Atom "user-state"
encodeLifetime StepLocalLifetime = Atom "step-local"

decodeLifetime :: SExpr -> Either CodecError Lifetime
decodeLifetime (Atom "user-state") = Right UserStateLifetime
decodeLifetime (Atom "step-local") = Right StepLocalLifetime
decodeLifetime expression = codecError "lifetime"
  ("unknown lifetime: " ++ renderSExpr expression)

encodeTimeSlot :: TimeSlot -> SExpr
encodeTimeSlot CurrentTime = Atom "current"
encodeTimeSlot NextTime = Atom "next"

decodeTimeSlot :: SExpr -> Either CodecError TimeSlot
decodeTimeSlot (Atom "current") = Right CurrentTime
decodeTimeSlot (Atom "next") = Right NextTime
decodeTimeSlot expression = codecError "time-slot"
  ("unknown time slot: " ++ renderSExpr expression)

encodeFunctionClass :: FunctionClass -> SExpr
encodeFunctionClass IntrinsicFunction = Atom "intrinsic"
encodeFunctionClass AnalyticFunction = Atom "analytic"
encodeFunctionClass ExternalFunction = Atom "external"

decodeFunctionClass :: SExpr -> Either CodecError FunctionClass
decodeFunctionClass (Atom "intrinsic") = Right IntrinsicFunction
decodeFunctionClass (Atom "analytic") = Right AnalyticFunction
decodeFunctionClass (Atom "external") = Right ExternalFunction
decodeFunctionClass expression = codecError "function-class"
  ("unknown function class: " ++ renderSExpr expression)

encodeCompareOp :: CompareOp -> SExpr
encodeCompareOp CompareEq = Atom "eq"
encodeCompareOp CompareNe = Atom "ne"
encodeCompareOp CompareLt = Atom "lt"
encodeCompareOp CompareLe = Atom "le"
encodeCompareOp CompareGt = Atom "gt"
encodeCompareOp CompareGe = Atom "ge"

decodeCompareOp :: SExpr -> Either CodecError CompareOp
decodeCompareOp (Atom "eq") = Right CompareEq
decodeCompareOp (Atom "ne") = Right CompareNe
decodeCompareOp (Atom "lt") = Right CompareLt
decodeCompareOp (Atom "le") = Right CompareLe
decodeCompareOp (Atom "gt") = Right CompareGt
decodeCompareOp (Atom "ge") = Right CompareGe
decodeCompareOp expression = codecError "compare-op"
  ("unknown comparison: " ++ renderSExpr expression)

-- ---------------------------------------------------------- logical registry

encodeAxisDecl :: AxisDecl -> SExpr
encodeAxisDecl axis = record "axis"
  [ ("id", encodeAxisId (axisDeclId axis))
  , ("source-name", encodeString (axisDeclSourceName axis))
  , ("canonical-name", encodeString (axisDeclCanonicalName axis))
  , ("boundary", encodeBoundaryCondition (axisDeclBoundary axis))
  , ("origin", encodeOriginId (axisDeclOrigin axis))
  ]

decodeAxisDecl :: SExpr -> Either CodecError AxisDecl
decodeAxisDecl expression = do
  fields <- decodeRecord "axis"
    ["id", "source-name", "canonical-name", "boundary", "origin"] expression
  AxisDecl
    <$> (required "id" fields >>= decodeAxisId)
    <*> (required "source-name" fields >>= decodeString "axis-source-name")
    <*> (required "canonical-name" fields >>= decodeString "axis-canonical-name")
    <*> (required "boundary" fields >>= decodeBoundaryCondition)
    <*> (required "origin" fields >>= decodeOriginId)

encodeBoundaryCondition :: BoundaryCondition -> SExpr
encodeBoundaryCondition condition =
  case condition of
    PeriodicBoundary -> List [Atom "periodic"]
    SbpBoundary -> List [Atom "sbp"]
    GhostBoundary fill -> List [Atom "ghost", encodeString fill]

decodeBoundaryCondition :: SExpr -> Either CodecError BoundaryCondition
decodeBoundaryCondition expression =
  case expression of
    List [Atom "periodic"] -> Right PeriodicBoundary
    List [Atom "sbp"] -> Right SbpBoundary
    List [Atom "ghost", fill] ->
      GhostBoundary <$> decodeString "boundary-ghost-fill" fill
    _ -> codecError "boundary"
      ("expected (periodic), (sbp), or (ghost fill), got "
       ++ renderSExpr expression)

encodeParameterDecl :: ParameterDecl -> SExpr
encodeParameterDecl parameter = record "parameter"
  [ ("id", encodeParamId (parameterDeclId parameter))
  , ("source-name", encodeString (parameterDeclSourceName parameter))
  , ("backend-name", encodeString (parameterDeclBackendName parameter))
  , ("raw-value", encodeString (parameterDeclRawValue parameter))
  , ("origin", encodeOriginId (parameterDeclOrigin parameter))
  ]

decodeParameterDecl :: SExpr -> Either CodecError ParameterDecl
decodeParameterDecl expression = do
  fields <- decodeRecord "parameter"
    ["id", "source-name", "backend-name", "raw-value", "origin"] expression
  ParameterDecl
    <$> (required "id" fields >>= decodeParamId)
    <*> (required "source-name" fields >>= decodeString "parameter-source-name")
    <*> (required "backend-name" fields >>= decodeString "parameter-backend-name")
    <*> (required "raw-value" fields >>= decodeString "parameter-raw-value")
    <*> (required "origin" fields >>= decodeOriginId)

encodeFunctionDecl :: FunctionDecl -> SExpr
encodeFunctionDecl function = record "function"
  [ ("id", encodeFunctionId (functionDeclId function))
  , ("source-name", encodeString (functionDeclSourceName function))
  , ("backend-name", encodeString (functionDeclBackendName function))
  , ("arity", encodeMaybe encodeInt (functionDeclArity function))
  , ("class", encodeFunctionClass (functionDeclClass function))
  , ("origin", encodeMaybe encodeOriginId (functionDeclOrigin function))
  ]

decodeFunctionDecl :: SExpr -> Either CodecError FunctionDecl
decodeFunctionDecl expression = do
  fields <- decodeRecord "function"
    ["id", "source-name", "backend-name", "arity", "class", "origin"] expression
  FunctionDecl
    <$> (required "id" fields >>= decodeFunctionId)
    <*> (required "source-name" fields >>= decodeString "function-source-name")
    <*> (required "backend-name" fields >>= decodeString "function-backend-name")
    <*> (required "arity" fields >>= decodeMaybe "function-arity" (decodeInt "arity"))
    <*> (required "class" fields >>= decodeFunctionClass)
    <*> (required "origin" fields >>= decodeMaybe "function-origin" decodeOriginId)

encodeTensorType :: TensorType -> SExpr
encodeTensorType tensorType = record "tensor-type"
  [ ("shape", encodeList encodeInt (tensorTypeShape tensorType))
  , ("variances", encodeList encodeVariance (tensorTypeVariances tensorType))
  , ("df-order", encodeInt (tensorTypeDfOrder tensorType))
  ]

decodeTensorType :: SExpr -> Either CodecError TensorType
decodeTensorType expression = do
  fields <- decodeRecord "tensor-type" ["shape", "variances", "df-order"] expression
  TensorType
    <$> (required "shape" fields >>= decodeList "tensor-type-shape" (decodeInt "shape"))
    <*> (required "variances" fields >>= decodeList "tensor-type-variances" decodeVariance)
    <*> (required "df-order" fields >>= decodeInt "tensor-type-df-order")

encodeLogicalFieldDecl :: LogicalFieldDecl -> SExpr
encodeLogicalFieldDecl logicalField = record "field"
  [ ("id", encodeFieldId (logicalFieldId logicalField))
  , ("source-name", encodeString (logicalFieldSourceName logicalField))
  , ("policy", encodeGridPolicy (logicalFieldPolicy logicalField))
  , ("tensor-type", encodeTensorType (logicalFieldTensorType logicalField))
  , ("layout", encodeLayout (logicalFieldLayout logicalField))
  , ("declared-variances",
      encodeList (encodeMaybe encodeVariance) (logicalFieldDeclaredVariances logicalField))
  , ("lifetime", encodeLifetime (logicalFieldLifetime logicalField))
  , ("origin", encodeOriginId (logicalFieldOrigin logicalField))
  ]

decodeLogicalFieldDecl :: SExpr -> Either CodecError LogicalFieldDecl
decodeLogicalFieldDecl expression = do
  fields <- decodeRecord "field"
    [ "id", "source-name", "policy", "tensor-type", "layout"
    , "declared-variances", "lifetime", "origin"
    ] expression
  LogicalFieldDecl
    <$> (required "id" fields >>= decodeFieldId)
    <*> (required "source-name" fields >>= decodeString "field-source-name")
    <*> (required "policy" fields >>= decodeGridPolicy)
    <*> (required "tensor-type" fields >>= decodeTensorType)
    <*> (required "layout" fields >>= decodeLayout)
    <*> (required "declared-variances" fields
          >>= decodeList "declared-variances" (decodeMaybe "declared-variance" decodeVariance))
    <*> (required "lifetime" fields >>= decodeLifetime)
    <*> (required "origin" fields >>= decodeOriginId)

encodeRawHelper :: RawHelper -> SExpr
encodeRawHelper helper = record "raw-helper"
  [ ("id", encodeRawHelperId (rawHelperId helper))
  , ("text", encodeString (rawHelperText helper))
  , ("origin", encodeOriginId (rawHelperOrigin helper))
  ]

decodeRawHelper :: SExpr -> Either CodecError RawHelper
decodeRawHelper expression = do
  fields <- decodeRecord "raw-helper" ["id", "text", "origin"] expression
  RawHelper
    <$> (required "id" fields >>= decodeRawHelperId)
    <*> (required "text" fields >>= decodeString "raw-helper-text")
    <*> (required "origin" fields >>= decodeOriginId)

-- --------------------------------------------------------------- geometry

encodeGeometryDecl :: GeometryDecl -> SExpr
encodeGeometryDecl geometry = record "geometry"
  [ ("id", encodeGeometryId (geometryDeclId geometry))
  , ("source-name", encodeMaybe encodeString (geometryDeclSourceName geometry))
  , ("origin", encodeMaybe encodeOriginId (geometryDeclOrigin geometry))
  , ("kind", encodeGeometryKind (geometryDeclKind geometry))
  ]

decodeGeometryDecl :: SExpr -> Either CodecError GeometryDecl
decodeGeometryDecl expression = do
  fields <- decodeRecord "geometry" ["id", "source-name", "origin", "kind"] expression
  GeometryDecl
    <$> (required "id" fields >>= decodeGeometryId)
    <*> (required "source-name" fields >>= decodeMaybe "geometry-source-name" (decodeString "name"))
    <*> (required "origin" fields >>= decodeMaybe "geometry-origin" decodeOriginId)
    <*> (required "kind" fields >>= decodeGeometryKind)

encodeGeometryKind :: GeometryKind -> SExpr
encodeGeometryKind EuclideanGeometry = List [Atom "euclidean"]
encodeGeometryKind (OrthogonalScaleGeometry factors normalForm) = record "orthogonal-scale"
  [ ("factors", encodeAxisScalarAssociations factors)
  , ("normal-form", encodeGeometryNF normalForm)
  ]
encodeGeometryKind (EmbeddedOrthogonalGeometry embedding normalForm) =
  record "embedded-orthogonal"
    [ ("embedding", encodeList encodeScalarNF embedding)
    , ("normal-form", encodeGeometryNF normalForm)
    ]

decodeGeometryKind :: SExpr -> Either CodecError GeometryKind
decodeGeometryKind (List [Atom "euclidean"]) = Right EuclideanGeometry
decodeGeometryKind expression@(List (Atom "orthogonal-scale" : _)) = do
  fields <- decodeRecord "orthogonal-scale" ["factors", "normal-form"] expression
  OrthogonalScaleGeometry
    <$> (required "factors" fields >>= decodeAxisScalarAssociations "orthogonal-scale-factors")
    <*> (required "normal-form" fields >>= decodeGeometryNF)
decodeGeometryKind expression@(List (Atom "embedded-orthogonal" : _)) = do
  fields <- decodeRecord "embedded-orthogonal" ["embedding", "normal-form"] expression
  EmbeddedOrthogonalGeometry
    <$> (required "embedding" fields >>= decodeList "embedding" decodeScalarNF)
    <*> (required "normal-form" fields >>= decodeGeometryNF)
decodeGeometryKind expression = codecError "geometry-kind"
  ("unknown geometry kind: " ++ renderSExpr expression)

encodeGeometryNF :: GeometryNF -> SExpr
encodeGeometryNF geometry = record "geometry-nf"
  [ ("metric", encodeTensorNF (geometryMetricComponents geometry))
  , ("inverse-metric", encodeTensorNF (geometryInverseMetric geometry))
  , ("scale-factors", encodeAxisScalarAssociations (geometryScaleFactors geometry))
  , ("volume", encodeScalarNF (geometryVolumeElement geometry))
  , ("orthogonality-verified", encodeBool (geometryOrthogonalityVerified geometry))
  ]

decodeGeometryNF :: SExpr -> Either CodecError GeometryNF
decodeGeometryNF expression = do
  fields <- decodeRecord "geometry-nf"
    ["metric", "inverse-metric", "scale-factors", "volume", "orthogonality-verified"]
    expression
  GeometryNF
    <$> (required "metric" fields >>= decodeTensorNF)
    <*> (required "inverse-metric" fields >>= decodeTensorNF)
    <*> (required "scale-factors" fields >>= decodeAxisScalarAssociations "geometry-scale-factors")
    <*> (required "volume" fields >>= decodeScalarNF)
    <*> (required "orthogonality-verified" fields >>= decodeBool "orthogonality-verified")

encodeAxisScalarAssociations :: [(AxisId, ScalarNF)] -> SExpr
encodeAxisScalarAssociations associations =
  encodeList encodeAssociation (sortOn fst associations)
  where
    encodeAssociation (axisId, value) = record "axis-value"
      [("axis", encodeAxisId axisId), ("value", encodeScalarNF value)]

decodeAxisScalarAssociations
  :: String -> SExpr -> Either CodecError [(AxisId, ScalarNF)]
decodeAxisScalarAssociations context expression = do
  associations <- decodeList context decodeAssociation expression
  rejectDuplicateKeys context (map fst associations)
  Right associations
  where
    decodeAssociation encoded = do
      fields <- decodeRecord "axis-value" ["axis", "value"] encoded
      (,) <$> (required "axis" fields >>= decodeAxisId)
          <*> (required "value" fields >>= decodeScalarNF)

-- --------------------------------------------------------- discretization

encodeDiscretizationProfile :: DiscretizationProfile -> SExpr
encodeDiscretizationProfile profile = record "discretization-profile"
  [ ("fingerprint", encodeFingerprint (discretizationProfileFingerprint profile))
  , ("rules", encodeList encodeDerivativeRule (sortRules (discretizationDerivativeRules profile)))
  , ("mixed", encodeMixedStencilRule (discretizationMixedRule profile))
  ]

decodeDiscretizationProfile :: SExpr -> Either CodecError DiscretizationProfile
decodeDiscretizationProfile expression = do
  fields <- decodeRecord "discretization-profile"
    ["fingerprint", "rules", "mixed"] expression
  profile <- DiscretizationProfile
    <$> (required "fingerprint" fields >>= decodeFingerprint)
    <*> (required "rules" fields >>= decodeList "derivative-rules" decodeDerivativeRule)
    <*> (required "mixed" fields >>= decodeMixedStencilRule)
  rejectDuplicateKeys "derivative-rules" (map ruleKey (discretizationDerivativeRules profile))
  Right profile

encodeDerivativeRule :: DerivativeRule -> SExpr
encodeDerivativeRule rule = record "derivative-rule"
  [ ("lattice", encodeLatticeClass (derivativeRuleLatticeClass rule))
  , ("order", encodeDerivativeOrder (derivativeRuleOrder rule))
  , ("family", encodeStencilFamily (derivativeRuleFamily rule))
  , ("accuracy", encodePositiveEven (derivativeRuleAccuracy rule))
  , ("origin", encodeOriginId (derivativeRuleOrigin rule))
  ]

decodeDerivativeRule :: SExpr -> Either CodecError DerivativeRule
decodeDerivativeRule expression = do
  fields <- decodeRecord "derivative-rule"
    ["lattice", "order", "family", "accuracy", "origin"] expression
  DerivativeRule
    <$> (required "lattice" fields >>= decodeLatticeClass)
    <*> (required "order" fields >>= decodeDerivativeOrder)
    <*> (required "family" fields >>= decodeStencilFamily)
    <*> (required "accuracy" fields >>= decodePositiveEven)
    <*> (required "origin" fields >>= decodeOriginId)

encodeDerivativeOrder :: Maybe Positive -> SExpr
encodeDerivativeOrder Nothing = Atom "default"
encodeDerivativeOrder (Just order) = encodePositive order

decodeDerivativeOrder :: SExpr -> Either CodecError (Maybe Positive)
decodeDerivativeOrder (Atom "default") = Right Nothing
decodeDerivativeOrder expression = Just <$> decodePositive expression

encodeLatticeClass :: LatticeClass -> SExpr
encodeLatticeClass CollocatedLattice = Atom "collocated"
encodeLatticeClass StaggeredLattice = Atom "staggered"

decodeLatticeClass :: SExpr -> Either CodecError LatticeClass
decodeLatticeClass (Atom "collocated") = Right CollocatedLattice
decodeLatticeClass (Atom "staggered") = Right StaggeredLattice
decodeLatticeClass expression = codecError "lattice-class"
  ("unknown lattice class: " ++ renderSExpr expression)

encodeStencilFamily :: StencilFamily -> SExpr
encodeStencilFamily CenteredTaylor = Atom "centered-taylor"
encodeStencilFamily Yee = Atom "yee"

decodeStencilFamily :: SExpr -> Either CodecError StencilFamily
decodeStencilFamily (Atom "centered-taylor") = Right CenteredTaylor
decodeStencilFamily (Atom "yee") = Right Yee
decodeStencilFamily expression = codecError "stencil-family"
  ("unknown stencil family: " ++ renderSExpr expression)

encodeMixedStencilRule :: MixedStencilRule -> SExpr
encodeMixedStencilRule FixedAxisOrder = Atom "fixed-axis-order"

decodeMixedStencilRule :: SExpr -> Either CodecError MixedStencilRule
decodeMixedStencilRule (Atom "fixed-axis-order") = Right FixedAxisOrder
decodeMixedStencilRule expression = codecError "mixed-stencil-rule"
  ("unknown mixed stencil rule: " ++ renderSExpr expression)

ruleKey :: DerivativeRule -> (LatticeClass, Maybe Positive)
ruleKey rule = (derivativeRuleLatticeClass rule, derivativeRuleOrder rule)

sortRules :: [DerivativeRule] -> [DerivativeRule]
sortRules = sortOn ruleKey

profileFingerprintPayload :: DiscretizationProfile -> SExpr
profileFingerprintPayload profile = record "discretization-profile-payload"
  [ ("schema", List [Atom "formurae-discretization", encodeInt 1])
  , ("rules", encodeList encodeRuleWithoutOrigin (sortRules (discretizationDerivativeRules profile)))
  , ("mixed", encodeMixedStencilRule (discretizationMixedRule profile))
  ]
  where
    encodeRuleWithoutOrigin rule = record "derivative-rule"
      [ ("lattice", encodeLatticeClass (derivativeRuleLatticeClass rule))
      , ("order", encodeDerivativeOrder (derivativeRuleOrder rule))
      , ("family", encodeStencilFamily (derivativeRuleFamily rule))
      , ("accuracy", encodePositiveEven (derivativeRuleAccuracy rule))
      ]

computeProfileFingerprint :: DiscretizationProfile -> Fingerprint
computeProfileFingerprint profile = Fingerprint
  ("sha256:" ++ sha256Utf8 (renderSExpr (profileFingerprintPayload profile)))

setProfileFingerprint :: DiscretizationProfile -> DiscretizationProfile
setProfileFingerprint profile = profile
  { discretizationProfileFingerprint = computeProfileFingerprint profile }

profileFingerprintMatches :: DiscretizationProfile -> Bool
profileFingerprintMatches profile =
  discretizationProfileFingerprint profile == computeProfileFingerprint profile

verifyProfileFingerprint :: DiscretizationProfile -> Either CodecError ()
verifyProfileFingerprint profile
  | profileFingerprintMatches profile = Right ()
  | otherwise = codecError "discretization-profile"
      ("fingerprint mismatch: expected "
       ++ show (computeProfileFingerprint profile) ++ ", got "
       ++ show (discretizationProfileFingerprint profile))

-- ------------------------------------------------------------- expressions

encodeTensorNF :: TensorNF -> SExpr
encodeTensorNF tensor = record "tensor"
  [ ("shape", encodeList encodeInt (tensorNFShape tensor))
  , ("variances", encodeList encodeVariance (tensorNFVariances tensor))
  , ("df-order", encodeInt (tensorNFDfOrder tensor))
  , ("components", encodeList encodeComponent (sortOn fst (tensorNFComponents tensor)))
  ]
  where
    encodeComponent (basis, value) = record "component"
      [("basis", encodeBasis basis), ("value", encodeScalarNF value)]

decodeTensorNF :: SExpr -> Either CodecError TensorNF
decodeTensorNF expression = do
  fields <- decodeRecord "tensor" ["shape", "variances", "df-order", "components"] expression
  componentsExpression <- required "components" fields
  components <- decodeList "tensor-components" decodeComponent componentsExpression
  rejectDuplicateKeys "tensor-components" (map fst components)
  TensorNF
    <$> (required "shape" fields >>= decodeList "tensor-shape" (decodeInt "shape"))
    <*> (required "variances" fields >>= decodeList "tensor-variances" decodeVariance)
    <*> (required "df-order" fields >>= decodeInt "tensor-df-order")
    <*> Right components
  where
    decodeComponent encoded = do
      fields <- decodeRecord "component" ["basis", "value"] encoded
      (,) <$> (required "basis" fields >>= decodeBasis)
          <*> (required "value" fields >>= decodeScalarNF)

encodeScalarNF :: ScalarNF -> SExpr
encodeScalarNF scalar =
  case scalar of
    Exact numerator denominator ->
      List [Atom "exact", encodeInteger numerator, encodeInteger denominator]
    NamedConstant constantName ->
      List [Atom "named-constant", encodeNamedConstant constantName]
    Parameter parameterId -> List [Atom "parameter", encodeParamId parameterId]
    Coordinate axisId -> List [Atom "coordinate", encodeAxisId axisId]
    Add terms -> List (Atom "add" : canonicalScalars terms)
    Mul factors -> List (Atom "mul" : canonicalScalars factors)
    Div numerator denominator ->
      List [Atom "div", encodeScalarNF numerator, encodeScalarNF denominator]
    Pow base exponentValue ->
      List [Atom "pow", encodeScalarNF base, encodeScalarNF exponentValue]
    Intrinsic functionId arguments ->
      List [Atom "intrinsic", encodeFunctionId functionId, encodeList encodeScalarNF arguments]
    AnalyticCall functionId arguments ->
      List [Atom "analytic-call", encodeFunctionId functionId, encodeList encodeScalarNF arguments]
    Select predicate yes no ->
      List [Atom "select", encodePredicateNF predicate, encodeScalarNF yes, encodeScalarNF no]
    FieldJet jet -> encodeFieldJet jet
    OpaqueDiscrete opaque -> encodeOpaqueDiscrete opaque
    Ref nodeId -> List [Atom "ref", encodeNodeId nodeId]

decodeScalarNF :: SExpr -> Either CodecError ScalarNF
decodeScalarNF expression =
  case expression of
    List [Atom "exact", numerator, denominator] ->
      Exact <$> decodeInteger "exact-numerator" numerator
            <*> decodeInteger "exact-denominator" denominator
    List [Atom "named-constant", constantName] ->
      NamedConstant <$> decodeNamedConstant constantName
    List [Atom "parameter", parameterId] -> Parameter <$> decodeParamId parameterId
    List [Atom "coordinate", axisId] -> Coordinate <$> decodeAxisId axisId
    List (Atom "add" : terms) ->
      Add <$> mapM decodeScalarNF terms
    List (Atom "mul" : factors) ->
      Mul <$> mapM decodeScalarNF factors
    List [Atom "div", numerator, denominator] ->
      Div <$> decodeScalarNF numerator <*> decodeScalarNF denominator
    List [Atom "pow", base, exponentValue] ->
      Pow <$> decodeScalarNF base <*> decodeScalarNF exponentValue
    List [Atom "intrinsic", functionId, arguments] ->
      Intrinsic <$> decodeFunctionId functionId
                <*> decodeList "intrinsic-arguments" decodeScalarNF arguments
    List [Atom "analytic-call", functionId, arguments] ->
      AnalyticCall <$> decodeFunctionId functionId
                   <*> decodeList "analytic-call-arguments" decodeScalarNF arguments
    List [Atom "select", predicate, yes, no] ->
      Select <$> decodePredicateNF predicate <*> decodeScalarNF yes <*> decodeScalarNF no
    List (Atom "field-jet" : _) -> FieldJet <$> decodeFieldJet expression
    List (Atom "opaque-discrete" : _) -> OpaqueDiscrete <$> decodeOpaqueDiscrete expression
    List [Atom "ref", nodeId] -> Ref <$> decodeNodeId nodeId
    List (Atom tag : _) -> codecError "scalar-nf" ("unknown scalar node: " ++ tag)
    _ -> codecError "scalar-nf" ("malformed scalar node: " ++ renderSExpr expression)

encodeNamedConstant :: NamedConstant -> SExpr
encodeNamedConstant constantName =
  case constantName of
    Pi -> Atom "pi"

decodeNamedConstant :: SExpr -> Either CodecError NamedConstant
decodeNamedConstant expression =
  case expression of
    Atom "pi" -> Right Pi
    Atom name -> codecError "named-constant" ("unknown constant: " ++ name)
    _ -> codecError "named-constant"
      ("malformed constant name: " ++ renderSExpr expression)

encodePredicateNF :: PredicateNF -> SExpr
encodePredicateNF predicate =
  case predicate of
    BoolExact value -> List [Atom "bool", encodeBool value]
    Compare operator lhs rhs ->
      List [Atom "compare", encodeCompareOp operator, encodeScalarNF lhs, encodeScalarNF rhs]
    Not body -> List [Atom "not", encodePredicateNF body]
    And bodies -> List (Atom "and" : canonicalPredicates bodies)
    Or bodies -> List (Atom "or" : canonicalPredicates bodies)

-- Egison's wire encoder orders nodes by their rendered canonical bytes.
-- Using the same key here matters for structurally nested lists: SExpr's
-- derived Ord places an empty list before a nonempty one, while byte order
-- places the opening parenthesis before the closing parenthesis.
canonicalScalars :: [ScalarNF] -> [SExpr]
canonicalScalars = sortOn renderSExpr . map encodeScalarNF

canonicalPredicates :: [PredicateNF] -> [SExpr]
canonicalPredicates = sortOn renderSExpr . map encodePredicateNF

decodePredicateNF :: SExpr -> Either CodecError PredicateNF
decodePredicateNF expression =
  case expression of
    List [Atom "bool", value] -> BoolExact <$> decodeBool "predicate-bool" value
    List [Atom "compare", operator, lhs, rhs] ->
      Compare <$> decodeCompareOp operator <*> decodeScalarNF lhs <*> decodeScalarNF rhs
    List [Atom "not", body] -> Not <$> decodePredicateNF body
    List (Atom "and" : bodies) ->
      And <$> mapM decodePredicateNF bodies
    List (Atom "or" : bodies) ->
      Or <$> mapM decodePredicateNF bodies
    List (Atom tag : _) -> codecError "predicate-nf" ("unknown predicate node: " ++ tag)
    _ -> codecError "predicate-nf" ("malformed predicate node: " ++ renderSExpr expression)

encodeFieldJet :: FieldJet -> SExpr
encodeFieldJet jet = record "field-jet"
  [ ("field", encodeFieldId (fieldJetFieldId jet))
  , ("time-slot", encodeTimeSlot (fieldJetTimeSlot jet))
  , ("basis", encodeBasis (fieldJetBasis jet))
  , ("arguments", encodeList encodeScalarNF (fieldJetArguments jet))
  , ("multi-index", encodeMultiIndex (fieldJetMultiIndex jet))
  ]

decodeFieldJet :: SExpr -> Either CodecError FieldJet
decodeFieldJet expression = do
  fields <- decodeRecord "field-jet"
    ["field", "time-slot", "basis", "arguments", "multi-index"] expression
  FieldJetValue
    <$> (required "field" fields >>= decodeFieldId)
    <*> (required "time-slot" fields >>= decodeTimeSlot)
    <*> (required "basis" fields >>= decodeBasis)
    <*> (required "arguments" fields >>= decodeList "field-jet-arguments" decodeScalarNF)
    <*> (required "multi-index" fields >>= decodeMultiIndex)

encodeMultiIndex :: [(AxisId, Natural)] -> SExpr
encodeMultiIndex multiIndex = encodeList encodeEntry (sortOn fst multiIndex)
  where
    encodeEntry (axisId, count) = record "axis-order"
      [("axis", encodeAxisId axisId), ("count", encodeNatural count)]

decodeMultiIndex :: SExpr -> Either CodecError [(AxisId, Natural)]
decodeMultiIndex expression = do
  multiIndex <- decodeList "multi-index" decodeEntry expression
  rejectDuplicateKeys "multi-index" (map fst multiIndex)
  Right multiIndex
  where
    decodeEntry encoded = do
      fields <- decodeRecord "axis-order" ["axis", "count"] encoded
      (,) <$> (required "axis" fields >>= decodeAxisId)
          <*> (required "count" fields >>= decodeNatural "derivative-count")

encodeOpaqueDiscrete :: OpaqueDiscrete -> SExpr
encodeOpaqueDiscrete opaque = record "opaque-discrete"
  [ ("op-id", encodeOpId (opaqueDiscreteOpId opaque))
  , ("semantic-key", encodeSemanticKey (opaqueDiscreteSemanticKey opaque))
  , ("request-group", encodeRequestGroupId (opaqueDiscreteRequestGroup opaque))
  , ("result-basis", encodeBasis (opaqueDiscreteResultBasis opaque))
  , ("operands", encodeList encodeFEValue (opaqueDiscreteOperands opaque))
  , ("attributes", encodeList encodeAttribute
       (sortOn attributeId (opaqueDiscreteAttributes opaque)))
  ]

decodeOpaqueDiscrete :: SExpr -> Either CodecError OpaqueDiscrete
decodeOpaqueDiscrete expression = do
  fields <- decodeRecord "opaque-discrete"
    ["op-id", "semantic-key", "request-group", "result-basis", "operands", "attributes"]
    expression
  attributesExpression <- required "attributes" fields
  attributes <- decodeList "attributes" decodeAttribute attributesExpression
  rejectDuplicateKeys "attributes" (map attributeId attributes)
  OpaqueDiscreteCall
    <$> (required "op-id" fields >>= decodeOpId)
    <*> (required "semantic-key" fields >>= decodeSemanticKey)
    <*> (required "request-group" fields >>= decodeRequestGroupId)
    <*> (required "result-basis" fields >>= decodeBasis)
    <*> (required "operands" fields >>= decodeList "opaque-operands" decodeFEValue)
    <*> Right attributes

encodeAttribute :: Attribute -> SExpr
encodeAttribute attribute = record "attribute"
  [ ("id", encodeAttributeId (attributeId attribute))
  , ("value", encodeAttributeValue (attributeValue attribute))
  ]

decodeAttribute :: SExpr -> Either CodecError Attribute
decodeAttribute expression = do
  fields <- decodeRecord "attribute" ["id", "value"] expression
  Attribute
    <$> (required "id" fields >>= decodeAttributeId)
    <*> (required "value" fields >>= decodeAttributeValue)

encodeAttributeValue :: AttributeValue -> SExpr
encodeAttributeValue value =
  case value of
    AttributeExact numerator denominator ->
      List [Atom "exact", encodeInteger numerator, encodeInteger denominator]
    AttributeNatural natural -> List [Atom "natural", encodeNatural natural]
    AttributeInteger integer -> List [Atom "integer", encodeInteger integer]
    AttributeBoolean boolean -> List [Atom "boolean", encodeBool boolean]
    AttributeString string -> List [Atom "string", encodeString string]
    AttributeAxis axisId -> List [Atom "axis", encodeAxisId axisId]
    AttributeParameter parameterId -> List [Atom "parameter", encodeParamId parameterId]
    AttributeFunction functionId -> List [Atom "function", encodeFunctionId functionId]
    AttributeField fieldId -> List [Atom "field", encodeFieldId fieldId]
    AttributeGeometry geometryId -> List [Atom "geometry", encodeGeometryId geometryId]
    AttributeGridPolicy policy -> List [Atom "grid-policy", encodeGridPolicy policy]
    AttributeTimeSlot timeSlot -> List [Atom "time-slot", encodeTimeSlot timeSlot]
    AttributeBasis basis -> List [Atom "basis-value", encodeBasis basis]
    AttributeValues values -> List [Atom "values", encodeList encodeAttributeValue values]

decodeAttributeValue :: SExpr -> Either CodecError AttributeValue
decodeAttributeValue expression =
  case expression of
    List [Atom "exact", numerator, denominator] ->
      AttributeExact <$> decodeInteger "attribute-numerator" numerator
                     <*> decodeInteger "attribute-denominator" denominator
    List [Atom "natural", natural] -> AttributeNatural <$> decodeNatural "attribute-natural" natural
    List [Atom "integer", integer] -> AttributeInteger <$> decodeInteger "attribute-integer" integer
    List [Atom "boolean", boolean] -> AttributeBoolean <$> decodeBool "attribute-boolean" boolean
    List [Atom "string", string] -> AttributeString <$> decodeString "attribute-string" string
    List [Atom "axis", axisId] -> AttributeAxis <$> decodeAxisId axisId
    List [Atom "parameter", parameterId] -> AttributeParameter <$> decodeParamId parameterId
    List [Atom "function", functionId] -> AttributeFunction <$> decodeFunctionId functionId
    List [Atom "field", fieldId] -> AttributeField <$> decodeFieldId fieldId
    List [Atom "geometry", geometryId] -> AttributeGeometry <$> decodeGeometryId geometryId
    List [Atom "grid-policy", policy] -> AttributeGridPolicy <$> decodeGridPolicy policy
    List [Atom "time-slot", timeSlot] -> AttributeTimeSlot <$> decodeTimeSlot timeSlot
    List [Atom "basis-value", basis] -> AttributeBasis <$> decodeBasis basis
    List [Atom "values", values] ->
      AttributeValues <$> decodeList "attribute-values" decodeAttributeValue values
    List (Atom tag : _) -> codecError "attribute-value" ("unknown attribute value: " ++ tag)
    _ -> codecError "attribute-value" ("malformed attribute value: " ++ renderSExpr expression)

encodeFEValue :: FEValue -> SExpr
encodeFEValue (ScalarValue scalar) = List [Atom "scalar", encodeScalarNF scalar]
encodeFEValue (TensorValue tensor) = List [Atom "tensor-value", encodeTensorNF tensor]

decodeFEValue :: SExpr -> Either CodecError FEValue
decodeFEValue (List [Atom "scalar", scalar]) = ScalarValue <$> decodeScalarNF scalar
decodeFEValue (List [Atom "tensor-value", tensor]) = TensorValue <$> decodeTensorNF tensor
decodeFEValue expression = codecError "fe-value"
  ("unknown FE value: " ++ renderSExpr expression)

-- -------------------------------------------------------- actions and model

encodeFieldTarget :: FieldTarget -> SExpr
encodeFieldTarget target =
  case target of
    WholeFieldTarget fieldId timeSlot -> record "field-target"
      [ ("kind", Atom "whole")
      , ("field", encodeFieldId fieldId)
      , ("time-slot", encodeTimeSlot timeSlot)
      , ("basis", encodeMaybe encodeBasis Nothing)
      ]
    FieldComponentTarget fieldId timeSlot basis -> record "field-target"
      [ ("kind", Atom "component")
      , ("field", encodeFieldId fieldId)
      , ("time-slot", encodeTimeSlot timeSlot)
      , ("basis", encodeMaybe encodeBasis (Just basis))
      ]

decodeFieldTarget :: SExpr -> Either CodecError FieldTarget
decodeFieldTarget expression = do
  fields <- decodeRecord "field-target" ["kind", "field", "time-slot", "basis"] expression
  kind <- required "kind" fields
  fieldId <- required "field" fields >>= decodeFieldId
  timeSlot <- required "time-slot" fields >>= decodeTimeSlot
  basis <- required "basis" fields >>= decodeMaybe "target-basis" decodeBasis
  case (kind, basis) of
    (Atom "whole", Nothing) -> Right (WholeFieldTarget fieldId timeSlot)
    (Atom "component", Just componentBasis) ->
      Right (FieldComponentTarget fieldId timeSlot componentBasis)
    (Atom "whole", Just _) -> codecError "field-target" "whole target must not have a basis"
    (Atom "component", Nothing) -> codecError "field-target" "component target needs a basis"
    (Atom unknown, _) -> codecError "field-target" ("unknown target kind: " ++ unknown)
    _ -> codecError "field-target" "target kind must be an atom"

encodeFEEquation :: FEEquation -> SExpr
encodeFEEquation equation = record "equation"
  [ ("id", encodeEquationId (feEquationId equation))
  , ("target", encodeFieldTarget (feEquationTarget equation))
  , ("rhs", encodeTensorNF (feEquationRhs equation))
  , ("origin", encodeOriginId (feEquationOrigin equation))
  ]

decodeFEEquation :: SExpr -> Either CodecError FEEquation
decodeFEEquation expression = do
  fields <- decodeRecord "equation" ["id", "target", "rhs", "origin"] expression
  FEEquation
    <$> (required "id" fields >>= decodeEquationId)
    <*> (required "target" fields >>= decodeFieldTarget)
    <*> (required "rhs" fields >>= decodeTensorNF)
    <*> (required "origin" fields >>= decodeOriginId)

encodeFEAction :: FEAction -> SExpr
encodeFEAction action =
  case action of
    BindValue nodeId value originId -> record "bind-value"
      [ ("node", encodeNodeId nodeId)
      , ("value", encodeFEValue value)
      , ("origin", encodeOriginId originId)
      ]
    Materialize fieldId value originId -> record "materialize"
      [ ("field", encodeFieldId fieldId)
      , ("value", encodeFEValue value)
      , ("origin", encodeOriginId originId)
      ]
    UpdateField equation -> record "update-field"
      [("equation", encodeFEEquation equation)]

decodeFEAction :: SExpr -> Either CodecError FEAction
decodeFEAction expression@(List (Atom "bind-value" : _)) = do
  fields <- decodeRecord "bind-value" ["node", "value", "origin"] expression
  BindValue
    <$> (required "node" fields >>= decodeNodeId)
    <*> (required "value" fields >>= decodeFEValue)
    <*> (required "origin" fields >>= decodeOriginId)
decodeFEAction expression@(List (Atom "materialize" : _)) = do
  fields <- decodeRecord "materialize" ["field", "value", "origin"] expression
  Materialize
    <$> (required "field" fields >>= decodeFieldId)
    <*> (required "value" fields >>= decodeFEValue)
    <*> (required "origin" fields >>= decodeOriginId)
decodeFEAction expression@(List (Atom "update-field" : _)) = do
  fields <- decodeRecord "update-field" ["equation"] expression
  UpdateField <$> (required "equation" fields >>= decodeFEEquation)
decodeFEAction expression = codecError "action"
  ("unknown action: " ++ renderSExpr expression)

encodeFEInitializer :: FEInitializer -> SExpr
encodeFEInitializer initializer =
  case initializer of
    AnalyticInitializer equation -> record "analytic-initializer"
      [("equation", encodeFEEquation equation)]
    RawInitializer target raw originId -> record "raw-initializer"
      [ ("target", encodeFieldTarget target)
      , ("raw", encodeString raw)
      , ("origin", encodeOriginId originId)
      ]

decodeFEInitializer :: SExpr -> Either CodecError FEInitializer
decodeFEInitializer expression@(List (Atom "analytic-initializer" : _)) = do
  fields <- decodeRecord "analytic-initializer" ["equation"] expression
  AnalyticInitializer <$> (required "equation" fields >>= decodeFEEquation)
decodeFEInitializer expression@(List (Atom "raw-initializer" : _)) = do
  fields <- decodeRecord "raw-initializer" ["target", "raw", "origin"] expression
  RawInitializer
    <$> (required "target" fields >>= decodeFieldTarget)
    <*> (required "raw" fields >>= decodeString "raw-initializer-text")
    <*> (required "origin" fields >>= decodeOriginId)
decodeFEInitializer expression = codecError "initializer"
  ("unknown initializer: " ++ renderSExpr expression)
