module Main where

import Numeric.Natural (Natural)

import Formurae.FEIR.Codec
  ( decodeFEProgram
  , encodeFEProgram
  , setProfileFingerprint
  )
import Formurae.FEIR.SExpr (SExpr(..))
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.Syntax
import Formurae.FEIR.Validate

axisX, axisY :: AxisId
axisX = AxisId 1
axisY = AxisId 2

origin1 :: OriginId
origin1 = OriginId 1

userField, localField :: FieldId
userField = FieldId 1
localField = FieldId 2

knownOpaqueOp :: VersionedOpId
knownOpaqueOp = VersionedOpId "grid-derivative@1"

knownSignature :: PrimitiveSignature
knownSignature = PrimitiveSignature
  { primitiveSignatureOpId = knownOpaqueOp
  , primitiveSignatureOpName = "grid-derivative"
  , primitiveSignatureOpVersion = 1
  , primitiveSignatureInputs = [ScalarCategory]
  , primitiveSignatureOutput = ScalarCategory
  , primitiveSignaturePlacement = DerivativeTargetPlacement
  , primitiveSignatureEffect = PureLocal
  , primitiveSignatureCommutation = Ordered
  }

knownManifestId :: PrimitiveManifestId
knownManifestId = primitiveManifestId (PrimitiveManifest 1 [knownSignature])

validationConfig :: ValidationConfig
validationConfig = ValidationConfig
  { validationExpectedRegistryId = Just (RegistryId "registry-test")
  , validationExpectedPrimitiveManifestId =
      Just knownManifestId
  , validationPrimitiveSignatures = [knownSignature]
  }

validProgram :: FEProgram
validProgram = FEProgram
  { feProgramVersion = 1
  , feProgramModel = ModelIdentity
      (ModelId "model-test") "test"
      (SourceIdentity (SourceId "source-test") "test.fme")
  , feProgramRegistryId = RegistryId "registry-test"
  , feProgramPrimitiveManifestId = knownManifestId
  , feProgramDiscretization = validProfile
  , feProgramMode = CollocatedMode
  , feProgramDimension = 2
  , feProgramAxes = validAxes
  , feProgramGeometry = GeometryDecl
      (GeometryId 1) Nothing (Just origin1) EuclideanGeometry
  , feProgramParameters =
      [ParameterDecl (ParamId 1) "dt" "dt" "0.1" origin1]
  , feProgramFunctions =
      [FunctionDecl (FunctionId 1) "exp" "exp" (Just 1)
         IntrinsicFunction (Just origin1)]
  , feProgramFields = [validUserField, validLocalField]
  , feProgramInitializers =
      [ AnalyticInitializer
          (FEEquation (EquationId 1)
            (WholeFieldTarget userField CurrentTime)
            (scalarTensor
              (Intrinsic (FunctionId 1) [Parameter (ParamId 1)]))
            origin1)
      ]
  , feProgramStepActions =
      [ BindValue (NodeId 1) (ScalarValue (OpaqueDiscrete validOpaque)) origin1
      , BindValue (NodeId 2) (TensorValue validVectorTensor) origin1
      , Materialize localField (ScalarValue (Ref (NodeId 1))) origin1
      , UpdateField
          (FEEquation (EquationId 2)
            (WholeFieldTarget userField NextTime)
            (scalarTensor
              (Add
                [ FieldJet (validJet localField CurrentTime [])
                , Ref (NodeId 1)
                ]))
            origin1)
      ]
  , feProgramRawHelpers =
      [RawHelper (RawHelperId 1) "extern function :: exp" origin1]
  , feProgramOrigins = OriginTable [(origin1, validOrigin)]
  , feProgramProvenance = ProvenanceTable
      [(NodeId 1, [origin1]), (NodeId 2, [origin1])]
  }

validProfile :: DiscretizationProfile
validProfile = setProfileFingerprint profile
  where
    profile = DiscretizationProfile
      (VersionedProfileId "formurae-discretization@1")
      (Fingerprint "")
      [ collocatedDefaultRule
      , DerivativeRule CollocatedLattice (Just (Positive 2)) CenteredTaylor
          (PositiveEven 4) origin1
      , DerivativeRule StaggeredLattice Nothing Yee
          (PositiveEven 2) origin1
      ]
      FixedAxisOrder

validAxes :: [AxisDecl]
validAxes =
  [ AxisDecl axisX "x" "x" origin1
  , AxisDecl axisY "y" "y" origin1
  ]

collocatedDefaultRule :: DerivativeRule
collocatedDefaultRule = DerivativeRule
  CollocatedLattice Nothing CenteredTaylor (PositiveEven 2) origin1

validUserField, validLocalField :: LogicalFieldDecl
validUserField = scalarField userField "u" UserStateLifetime
validLocalField = scalarField localField "flux" StepLocalLifetime

validOrigin :: SourceOrigin
validOrigin = SourceOrigin
  (SourceLocation (SourceId "source-test") "test.fme" 1 1 1 10)
  []

scalarField :: FieldId -> String -> Lifetime -> LogicalFieldDecl
scalarField fieldId name lifetime = LogicalFieldDecl
  { logicalFieldId = fieldId
  , logicalFieldSourceName = name
  , logicalFieldPolicy = CollocatedPolicy
  , logicalFieldTensorType = TensorType [] [] 0
  , logicalFieldLayout = ScalarLayout
  , logicalFieldDeclaredVariances = []
  , logicalFieldLifetime = lifetime
  , logicalFieldOrigin = origin1
  }

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

validVectorTensor :: TensorNF
validVectorTensor = TensorNF [2] [VarianceDown] 0
  [(Basis [1], Exact 1 1), (Basis [2], Exact 2 1)]

validJet :: FieldId -> TimeSlot -> [(AxisId, Natural)] -> FieldJet
validJet fieldId timeSlot multiIndex = FieldJetValue
  { fieldJetFieldId = fieldId
  , fieldJetTimeSlot = timeSlot
  , fieldJetBasis = Basis []
  , fieldJetArguments = [Coordinate axisX, Coordinate axisY]
  , fieldJetMultiIndex = multiIndex
  }

validOpaque :: OpaqueDiscrete
validOpaque = OpaqueDiscreteCall
  { opaqueDiscreteOpId = knownOpaqueOp
  , opaqueDiscreteSemanticKey = SemanticKey "grid-u-xy"
  , opaqueDiscreteRequestGroup = RequestGroupId "grid-group-1"
  , opaqueDiscreteResultBasis = Basis []
  , opaqueDiscreteOperands =
      [ScalarValue (FieldJet
        (validJet userField CurrentTime [(axisX, 1), (axisY, 2)]))]
  , opaqueDiscreteAttributes =
      [Attribute (AttributeId "axis") (AttributeAxis axisX)]
  }

main :: IO ()
main = do
  assertEqual "positive FEIR fixture" (Right ())
    (validateFEProgram validationConfig validProgram)
  checkHeaderAndIds
  checkTensorAndExact
  checkNormalForms
  checkFieldJet
  checkReferencesAndActions
  checkProfile
  checkOpaque
  checkOriginsAndProvenance
  checkCanonicalWireOrder
  putStrLn "FEIR validation tests: ok"

checkHeaderAndIds :: IO ()
checkHeaderAndIds = do
  assertIssue "version 1 is required" isVersion
    validProgram { feProgramVersion = 2 }
  let duplicateAxes =
        [ AxisDecl axisX "x" "x" origin1
        , AxisDecl axisX "y" "y" origin1
        ]
  assertIssue "axis IDs are unique" isDuplicateAxis
    validProgram { feProgramAxes = duplicateAxes }
  assertIssue "dimension matches axes" isAxisCount
    validProgram { feProgramDimension = 3 }
  assertIssue "parameter references are declared" isUnknownParameter
    (mapInitializerScalar (const (Parameter (ParamId 99))) validProgram)
  where
    isVersion (UnsupportedProgramVersion 1 2) = True
    isVersion _ = False
    isDuplicateAxis (DuplicateIdentifier AxisIds _) = True
    isDuplicateAxis _ = False
    isAxisCount (AxisCountMismatch 3 2) = True
    isAxisCount _ = False
    isUnknownParameter (UnknownReference ParameterIds _) = True
    isUnknownParameter _ = False

checkTensorAndExact :: IO ()
checkTensorAndExact = do
  let badTensor = TensorNF [2] [VarianceDown] 0
        [(Basis [2], Exact 2 1), (Basis [1], Exact 1 1)]
  assertIssue "tensor components use full row-major basis" isBasisOrder
    (mapInitializerTensor (const badTensor) validProgram)
  assertIssue "exact rationals are reduced with positive denominator" isExact
    (mapInitializerScalar (const (Exact 2 4)) validProgram)
  let badField = validUserField
        { logicalFieldTensorType = TensorType [2] [] 2 }
  assertIssue "variance count matches shape" isVariance
    validProgram { feProgramFields = [badField, validLocalField] }
  assertIssue "dfOrder is within tensor rank" isDfOrder
    (mapInitializerTensor
      (\tensor -> tensor { tensorNFDfOrder = 1 }) validProgram)
  where
    isBasisOrder (ComponentBasisMismatch _ _) = True
    isBasisOrder _ = False
    isExact (NonCanonicalExact 2 4) = True
    isExact _ = False
    isVariance (VarianceCountMismatch 1 0) = True
    isVariance _ = False
    isDfOrder (InvalidDifferentialFormOrder 1 0) = True
    isDfOrder _ = False

checkNormalForms :: IO ()
checkNormalForms = do
  assertIssue "singleton add is not canonical" isScalarForm
    (mapInitializerScalar (const (Add [Exact 1 1])) validProgram)
  assertIssue "nested multiplication is flattened" isScalarForm
    (mapInitializerScalar
      (const (Mul [Parameter (ParamId 1), Mul [Exact 2 1, Exact 3 1]]))
      validProgram)
  assertIssue "additive identities are removed" isScalarForm
    (mapInitializerScalar
      (const (Add [Exact 0 1, Parameter (ParamId 1)])) validProgram)
  assertIssue "division by zero is rejected" isDivisionByZero
    (mapInitializerScalar
      (const (Div (Exact 1 1) (Exact 0 1))) validProgram)
  assertIssue "trivial powers are reduced" isScalarForm
    (mapInitializerScalar
      (const (Pow (Parameter (ParamId 1)) (Exact 1 1))) validProgram)
  assertIssue "like terms carry one combined coefficient" isScalarForm
    (mapInitializerScalar
      (const (Add
        [ Mul [Exact 2 1, Parameter (ParamId 1)]
        , Parameter (ParamId 1)
        ]))
      validProgram)
  assertIssue "constant addends are folded into one exact value" isScalarForm
    (mapInitializerScalar
      (const (Add [Exact 1 1, Exact 2 1])) validProgram)
  assertIssue "multiplication has at most one exact coefficient" isScalarForm
    (mapInitializerScalar
      (const (Mul [Exact 2 1, Exact 3 1, Parameter (ParamId 1)]))
      validProgram)
  assertIssue "repeated multiplication factors are combined" isScalarForm
    (mapInitializerScalar
      (const (Mul [Parameter (ParamId 1), Parameter (ParamId 1)]))
      validProgram)
  assertIssue "zero numerator divisions are reduced" isScalarForm
    (mapInitializerScalar
      (const (Div (Exact 0 1) (Parameter (ParamId 1)))) validProgram)
  assertIssue "self divisions are reduced" isScalarForm
    (mapInitializerScalar
      (const (Div (Parameter (ParamId 1)) (Parameter (ParamId 1))))
      validProgram)
  assertIssue "exact divisions are folded" isScalarForm
    (mapInitializerScalar
      (const (Div (Exact 2 1) (Exact 3 1))) validProgram)
  assertIssue "exact integer powers are folded" isScalarForm
    (mapInitializerScalar
      (const (Pow (Exact 2 1) (Exact 3 1))) validProgram)
  assertIssue "singleton predicates are not canonical" isPredicateForm
    (mapInitializerScalar
      (const (Select (And [BoolExact True]) (Exact 1 1) (Exact 0 1)))
      validProgram)
  let predicate = Compare CompareLt (Coordinate axisX) (Exact 1 1)
  assertIssue "duplicate predicates are removed" isPredicateForm
    (mapInitializerScalar
      (const (Select (And [predicate, predicate]) (Exact 1 1) (Exact 0 1)))
      validProgram)
  assertIssue "boolean predicate operands are simplified" isPredicateForm
    (mapInitializerScalar
      (const (Select
        (Or [BoolExact False, predicate]) (Exact 1 1) (Exact 0 1)))
      validProgram)
  where
    isScalarForm (NonCanonicalScalarForm _) = True
    isScalarForm _ = False
    isDivisionByZero DivisionByZero = True
    isDivisionByZero _ = False
    isPredicateForm (NonCanonicalPredicateForm _) = True
    isPredicateForm _ = False

checkFieldJet :: IO ()
checkFieldJet = do
  let badJet = (validJet userField CurrentTime [(axisY, 1), (axisX, 0)])
        { fieldJetArguments = [Coordinate axisY, Coordinate axisX] }
      badOpaque = validOpaque
        { opaqueDiscreteOperands = [ScalarValue (FieldJet badJet)] }
  assertIssue "field arguments are the canonical coordinate vector" isArguments
    (replaceFirstBind (ScalarValue (OpaqueDiscrete badOpaque)) validProgram)
  assertIssue "multi-index is positive, unique, and axis ordered" isMultiIndex
    (replaceFirstBind (ScalarValue (OpaqueDiscrete badOpaque)) validProgram)
  where
    isArguments (NonCanonicalFieldArguments _ _) = True
    isArguments _ = False
    isMultiIndex (NonCanonicalMultiIndex _) = True
    isMultiIndex _ = False

checkReferencesAndActions :: IO ()
checkReferencesAndActions = do
  let forwardActions =
        [ BindValue (NodeId 1) (ScalarValue (Ref (NodeId 2))) origin1
        , BindValue (NodeId 2) (ScalarValue (Exact 1 1)) origin1
        ]
      forwardProgram = validProgram
        { feProgramStepActions = forwardActions
        , feProgramProvenance = ProvenanceTable
            [(NodeId 1, [origin1]), (NodeId 2, [origin1])]
        }
  assertIssue "Ref points only to a preceding binding" isForward forwardProgram
  assertIssue "initializer Ref cannot capture step bindings" isOutside
    (mapInitializerScalar (const (Ref (NodeId 1))) validProgram)
  let badUpdate = mapUpdateTarget
        (\_ -> WholeFieldTarget userField CurrentTime) validProgram
  assertIssue "updates target NextTime" isTargetTime badUpdate
  let badMaterialize = replaceMaterializeTarget userField validProgram
  assertIssue "materialization targets a step-local field" isLifetime
    badMaterialize
  let nextJet = FieldJet (validJet userField NextTime [])
  assertIssue "NextTime fields must have been updated earlier" isUnavailable
    (replaceFirstBind (ScalarValue nextJet) validProgram)
  where
    isForward (RefNotPreceding (NodeId 2)) = True
    isForward _ = False
    isOutside (RefOutsideActionStream (NodeId 1)) = True
    isOutside _ = False
    isTargetTime (InvalidTargetTime NextTime CurrentTime) = True
    isTargetTime _ = False
    isLifetime (InvalidFieldLifetime fid StepLocalLifetime UserStateLifetime) =
      fid == userField
    isLifetime _ = False
    isUnavailable (FieldValueNotAvailable fid NextTime) = fid == userField
    isUnavailable _ = False

checkProfile :: IO ()
checkProfile = do
  let wrongVersion = validProfile
        { discretizationProfileVersion = VersionedProfileId "other@2" }
  assertIssue "profile schema version is fixed" isProfileVersion
    validProgram { feProgramDiscretization = wrongVersion }
  let malformedRule = DerivativeRule CollocatedLattice Nothing Yee
        (PositiveEven 3) origin1
      malformedProfile = validProfile
        { discretizationDerivativeRules =
            [ DerivativeRule StaggeredLattice Nothing Yee
                (PositiveEven 2) origin1
            , malformedRule
            , collocatedDefaultRule
            , collocatedDefaultRule
            ] }
      malformedProgram = validProgram
        { feProgramDiscretization = malformedProfile }
  assertIssue "profile family matches lattice" isFamily malformedProgram
  assertIssue "profile accuracy is positive even" isAccuracy malformedProgram
  assertIssue "profile rule keys are unique" isDuplicateRule malformedProgram
  assertIssue "profile rules have canonical order" isRuleOrder malformedProgram
  let tampered = validProfile
        { discretizationProfileFingerprint = Fingerprint "tampered" }
  assertIssue "profile fingerprint is recomputed" isFingerprint
    validProgram { feProgramDiscretization = tampered }
  where
    isProfileVersion (UnsupportedProfileVersion (VersionedProfileId "other@2")) = True
    isProfileVersion _ = False
    isFamily (InvalidLatticeFamily CollocatedLattice Yee) = True
    isFamily _ = False
    isAccuracy (InvalidFormalAccuracy 3) = True
    isAccuracy _ = False
    isDuplicateRule (DuplicateDerivativeRule CollocatedLattice Nothing) = True
    isDuplicateRule _ = False
    isRuleOrder (NonCanonicalOrder "derivative rules") = True
    isRuleOrder _ = False
    isFingerprint (ProfileFingerprintMismatch _ (Fingerprint "tampered")) = True
    isFingerprint _ = False

checkOpaque :: IO ()
checkOpaque = do
  let badOpaque = validOpaque
        { opaqueDiscreteOpId = VersionedOpId "unknown@1"
        , opaqueDiscreteSemanticKey = SemanticKey ""
        }
      badProgram = replaceFirstBind
        (ScalarValue (OpaqueDiscrete badOpaque)) validProgram
  assertIssue "opaque operation ID is manifest-known" isUnknownOp badProgram
  assertIssue "opaque semantic key is nonempty" isEmptyKey badProgram
  assertIssue "opaque operand count follows the manifest signature"
    isOperandCount
    (replaceFirstBind
      (ScalarValue (OpaqueDiscrete validOpaque
        { opaqueDiscreteOperands = [] })) validProgram)
  assertIssue "opaque operand category follows the manifest signature"
    isOperandCategory
    (replaceFirstBind
      (ScalarValue (OpaqueDiscrete validOpaque
        { opaqueDiscreteOperands = [TensorValue validVectorTensor] }))
      validProgram)
  let badResult = validOpaque { opaqueDiscreteResultBasis = Basis [1] }
  assertIssue "opaque output category follows the manifest signature"
    isOutputCategory
    (replaceFirstBind (ScalarValue (OpaqueDiscrete badResult)) validProgram)

  let effectSignature = knownSignature
        { primitiveSignatureEffect =
            NeedsMaterialization [IntermediateRole] }
      effectProgram = withSignature effectSignature
        (mapInitializerScalar (const (OpaqueDiscrete validOpaque)) validProgram)
  assertIssueWith "materializing effects are step-only"
    (configForSignature effectSignature) isEffectContext effectProgram

  let cellSignature = knownSignature
        { primitiveSignaturePlacement = ConservativeCellPlacement }
      cellProgram = withSignature cellSignature
        (replaceFirstBind (ScalarValue (OpaqueDiscrete badResult)) validProgram)
  assertIssueWith "placement contract follows the manifest signature"
    (configForSignature cellSignature) isPlacement cellProgram

  let incompatibleSignature = knownSignature
        { primitiveSignatureOutput = TensorCategory }
      incompatibleConfig = validationConfig
        { validationPrimitiveSignatures = [incompatibleSignature] }
  assertIssueWith "signature table is validated before FEIR calls"
    incompatibleConfig isInvalidSignatureTable validProgram
  assertIssueWith "signature table fingerprint matches the manifest ID"
    incompatibleConfig isSignatureTableMismatch validProgram
  let conflicting = validOpaque
        { opaqueDiscreteOperands = [ScalarValue (Exact 9 1)] }
      actions = feProgramStepActions validProgram
      conflictProgram = validProgram
        { feProgramStepActions =
            take 1 actions
            ++ [BindValue (NodeId 3)
                  (ScalarValue (OpaqueDiscrete conflicting)) origin1]
            ++ drop 1 actions
        , feProgramProvenance = ProvenanceTable
            [ (NodeId 1, [origin1])
            , (NodeId 2, [origin1])
            , (NodeId 3, [origin1])
            ]
        }
  assertIssue "one semantic key has one semantic payload" isConflict
    conflictProgram
  where
    isUnknownOp (UnknownOpaqueOperation (VersionedOpId "unknown@1")) = True
    isUnknownOp _ = False
    isEmptyKey EmptyOpaqueSemanticKey = True
    isEmptyKey _ = False
    isConflict (ConflictingOpaqueSemanticKey (SemanticKey "grid-u-xy")) = True
    isConflict _ = False
    isOperandCount (OpaqueOperandCountMismatch operation 1 0) =
      operation == knownOpaqueOp
    isOperandCount _ = False
    isOperandCategory (OpaqueOperandCategoryMismatch operation 0 ScalarCategory) =
      operation == knownOpaqueOp
    isOperandCategory _ = False
    isOutputCategory (OpaqueOutputCategoryMismatch operation ScalarCategory
        (Basis [1])) = operation == knownOpaqueOp
    isOutputCategory _ = False
    isEffectContext (OpaqueEffectContextMismatch operation
        (NeedsMaterialization [IntermediateRole])) = operation == knownOpaqueOp
    isEffectContext _ = False
    isPlacement (OpaquePlacementContractMismatch operation
        ConservativeCellPlacement (Basis [1])) = operation == knownOpaqueOp
    isPlacement _ = False
    isInvalidSignatureTable (InvalidPrimitiveSignatureTable _) = True
    isInvalidSignatureTable _ = False
    isSignatureTableMismatch (PrimitiveSignatureTableManifestMismatch _ _) = True
    isSignatureTableMismatch _ = False

checkOriginsAndProvenance :: IO ()
checkOriginsAndProvenance = do
  let unknownOriginProgram = validProgram
        { feProgramFields =
            [ validUserField { logicalFieldOrigin = OriginId 99 }
            , validLocalField
            ] }
  assertIssue "origin references resolve" isUnknownOrigin unknownOriginProgram
  let badProvenance = validProgram
        { feProgramProvenance = ProvenanceTable
            [(NodeId 99, [OriginId 99])] }
  assertIssue "provenance node references resolve" isUnknownNode badProvenance
  assertIssue "provenance origin references resolve" isUnknownOrigin badProvenance
  where
    isUnknownOrigin (UnknownReference OriginIds _) = True
    isUnknownOrigin _ = False
    isUnknownNode (UnknownReference NodeIds _) = True
    isUnknownNode _ = False

checkCanonicalWireOrder :: IO ()
checkCanonicalWireOrder = do
  let parameter = Parameter (ParamId 1)
      compareEq = Compare CompareEq (Coordinate axisX) (Exact 0 1)
      compareLt = Compare CompareLt (Coordinate axisX) (Exact 1 1)
      scalarProgram scalar = mapInitializerScalar (const scalar) validProgram
  assertMalformedWireIssue "Add wire operands retain source order"
    (isOrder "add operands")
    (scalarProgram (Add [Exact 2 1, parameter]))
    (reverseTaggedChildren "add")
  assertMalformedWireIssue "Mul wire operands retain source order"
    (isOrder "mul operands")
    (scalarProgram (Mul [Exact 2 1, parameter]))
    (reverseTaggedChildren "mul")
  assertMalformedWireIssue "And wire predicates retain source order"
    (isOrder "and predicates")
    (scalarProgram
      (Select (And [compareEq, compareLt]) (Exact 1 1) (Exact 0 1)))
    (reverseTaggedChildren "and")
  assertMalformedWireIssue "Or wire predicates retain source order"
    (isOrder "or predicates")
    (scalarProgram
      (Select (Or [compareEq, compareLt]) (Exact 1 1) (Exact 0 1)))
    (reverseTaggedChildren "or")
  assertMalformedWireIssue "tensor component wire order is not repaired"
    (isOrder "tensor components") validProgram
    (reverseRecordListField "tensor" "components")
  assertMalformedWireIssue "FieldJet multi-index wire order is not repaired"
    isMultiIndex validProgram
    (reverseRecordListField "field-jet" "multi-index")

  let attributesProgram = replaceFirstBind
        (ScalarValue (OpaqueDiscrete validOpaque
          { opaqueDiscreteAttributes =
              [ Attribute (AttributeId "axis") (AttributeAxis axisX)
              , Attribute (AttributeId "policy")
                  (AttributeGridPolicy CollocatedPolicy)
              ]
          }))
        validProgram
  assertMalformedWireIssue "opaque attribute wire order is not repaired"
    (isOrder "opaque attributes") attributesProgram
    (reverseRecordListField "opaque-discrete" "attributes")

  assertMalformedWireIssue "profile rule wire order is not repaired"
    (isOrder "derivative rules") validProgram
    (reverseRecordListField "discretization-profile" "rules")

  let origin2 = OriginId 2
      secondOrigin = SourceOrigin
        (SourceLocation (SourceId "source-test") "test.fme" 2 2 1 10) []
      twoOriginProgram = validProgram
        { feProgramOrigins = OriginTable
            [(origin1, validOrigin), (origin2, secondOrigin)] }
  assertMalformedWireIssue "origin table wire order is not repaired"
    (isOrder "origin table") twoOriginProgram
    (reverseRecordListField "feir" "origins")
  assertMalformedWireIssue "provenance table wire order is not repaired"
    (isOrder "provenance table") validProgram
    (reverseRecordListField "feir" "provenance")
  let multiOriginProvenance = twoOriginProgram
        { feProgramProvenance = ProvenanceTable
            [ (NodeId 1, [origin1, origin2])
            , (NodeId 2, [origin1])
            ] }
  assertMalformedWireIssue "provenance origin wire order is not repaired"
    (isOrder "provenance origins") multiOriginProvenance
    (reverseRecordListField "provenance-entry" "origins")

  assertEqual "orthogonal association fixture is canonical" (Right ())
    (validateFEProgram validationConfig orthogonalProgram)
  assertMalformedWireIssue "axis association wire order is not repaired"
    (isOrder "axis scalar list") orthogonalProgram
    (reverseRecordListField "orthogonal-scale" "factors")
  where
    isOrder expected (NonCanonicalOrder actual) = actual == expected
    isOrder _ _ = False
    isMultiIndex (NonCanonicalMultiIndex _) = True
    isMultiIndex _ = False

orthogonalProgram :: FEProgram
orthogonalProgram = validProgram
  { feProgramGeometry = GeometryDecl
      (GeometryId 1) Nothing (Just origin1)
      (OrthogonalScaleGeometry scaleFactors geometryNF)
  }
  where
    scaleFactors = [(axisX, Exact 1 1), (axisY, Exact 1 1)]
    geometryNF = GeometryNF metric metric scaleFactors (Exact 1 1) True
    metric = TensorNF [2, 2] [VarianceDown, VarianceDown] 0
      [ (Basis [1, 1], Exact 1 1)
      , (Basis [1, 2], Exact 0 1)
      , (Basis [2, 1], Exact 0 1)
      , (Basis [2, 2], Exact 1 1)
      ]

assertMalformedWireIssue
    :: String
    -> (ValidationIssue -> Bool)
    -> FEProgram
    -> (SExpr -> SExpr)
    -> IO ()
assertMalformedWireIssue label predicate program mutate =
  let canonicalWire = encodeFEProgram program
      malformedWire = mutate canonicalWire
  in if malformedWire == canonicalWire
       then fail (label ++ ": test did not mutate the canonical wire")
       else case decodeFEProgram malformedWire of
         Left err -> fail (label ++ ": decoder did not preserve the wire: " ++ show err)
         Right decoded ->
           case validateFEProgram validationConfig decoded of
             Right () -> fail (label ++ ": noncanonical wire was accepted")
             Left errors
               | any (predicate . validationErrorIssue) errors -> return ()
               | otherwise -> fail
                   (label ++ ": expected canonical-order issue was absent; got "
                     ++ show errors)

reverseTaggedChildren :: String -> SExpr -> SExpr
reverseTaggedChildren tag = rewriteFirst rewrite
  where
    rewrite expression =
      case expression of
        List (Atom actual : values)
          | actual == tag
          , length values > 1
          , reverse values /= values ->
              Just (List (Atom actual : reverse values))
        _ -> Nothing

reverseRecordListField :: String -> String -> SExpr -> SExpr
reverseRecordListField recordTag fieldName = rewriteFirst rewrite
  where
    rewrite expression =
      case expression of
        List (Atom actual : fields)
          | actual == recordTag ->
              List . (Atom actual :) <$> reverseNamedListField fieldName fields
        _ -> Nothing

reverseNamedListField :: String -> [SExpr] -> Maybe [SExpr]
reverseNamedListField _ [] = Nothing
reverseNamedListField name (field : rest) =
  case field of
    List [Atom actual, List values]
      | actual == name
      , length values > 1
      , reverse values /= values ->
          Just (List [Atom actual, List (reverse values)] : rest)
    _ -> (field :) <$> reverseNamedListField name rest

rewriteFirst :: (SExpr -> Maybe SExpr) -> SExpr -> SExpr
rewriteFirst rewrite = fst . go
  where
    go expression =
      case rewrite expression of
        Just rewritten -> (rewritten, True)
        Nothing ->
          case expression of
            List values ->
              let (rewrittenValues, changed) = goList values
              in (List rewrittenValues, changed)
            _ -> (expression, False)

    goList [] = ([], False)
    goList (value : rest) =
      let (rewrittenValue, changed) = go value
      in if changed
           then (rewrittenValue : rest, True)
           else let (rewrittenRest, restChanged) = goList rest
                in (value : rewrittenRest, restChanged)

mapInitializerScalar :: (ScalarNF -> ScalarNF) -> FEProgram -> FEProgram
mapInitializerScalar transform = mapInitializerTensor mapTensor
  where
    mapTensor tensor = tensor
      { tensorNFComponents =
          [(basis, transform scalar) | (basis, scalar) <- tensorNFComponents tensor] }

mapInitializerTensor :: (TensorNF -> TensorNF) -> FEProgram -> FEProgram
mapInitializerTensor transform program = program
  { feProgramInitializers = map mapInitializer (feProgramInitializers program) }
  where
    mapInitializer initializer = case initializer of
      AnalyticInitializer equation ->
        AnalyticInitializer equation
          { feEquationRhs = transform (feEquationRhs equation) }
      RawInitializer {} -> initializer

replaceFirstBind :: FEValue -> FEProgram -> FEProgram
replaceFirstBind value program = program
  { feProgramStepActions = case feProgramStepActions program of
      BindValue node _ origin : rest -> BindValue node value origin : rest
      actions -> actions
  }

configForSignature :: PrimitiveSignature -> ValidationConfig
configForSignature signature = validationConfig
  { validationExpectedPrimitiveManifestId = Just manifestId
  , validationPrimitiveSignatures = [signature]
  }
  where
    manifestId = primitiveManifestId (PrimitiveManifest 1 [signature])

withSignature :: PrimitiveSignature -> FEProgram -> FEProgram
withSignature signature program = program
  { feProgramPrimitiveManifestId = primitiveManifestId
      (PrimitiveManifest 1 [signature]) }

replaceMaterializeTarget :: FieldId -> FEProgram -> FEProgram
replaceMaterializeTarget fieldId program = program
  { feProgramStepActions = map replace (feProgramStepActions program) }
  where
    replace action = case action of
      Materialize _ value origin -> Materialize fieldId value origin
      _ -> action

mapUpdateTarget :: (FieldTarget -> FieldTarget) -> FEProgram -> FEProgram
mapUpdateTarget transform program = program
  { feProgramStepActions = map replace (feProgramStepActions program) }
  where
    replace action = case action of
      UpdateField equation -> UpdateField equation
        { feEquationTarget = transform (feEquationTarget equation) }
      _ -> action

assertIssue :: String -> (ValidationIssue -> Bool) -> FEProgram -> IO ()
assertIssue label predicate program =
  assertIssueWith label validationConfig predicate program

assertIssueWith
    :: String
    -> ValidationConfig
    -> (ValidationIssue -> Bool)
    -> FEProgram
    -> IO ()
assertIssueWith label config predicate program =
  case validateFEProgram config program of
    Right () -> fail (label ++ ": invalid program was accepted")
    Left errors
      | any (predicate . validationErrorIssue) errors -> return ()
      | otherwise -> fail
          (label ++ ": expected issue was absent; got " ++ show errors)

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = return ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
