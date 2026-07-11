module Main where

import Data.List (isInfixOf)

import Formurae.FEIR.Codec
import Formurae.FEIR.SExpr
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  let program = fixtureProgram
      encoded = encodeFEProgram program
      rendered = renderFEProgram program

  assertRightEqual "S-expression round trip" program (decodeFEProgram encoded)
  assertRightEqual "UTF-8 text round trip" program (parseFEProgram rendered)
  assert "canonical text is stable"
    (case parseFEProgram rendered of
       Right decoded -> renderFEProgram decoded == rendered
       Left _ -> False)
  assert "UTF-8 source/model/raw text survives"
    (all (`isInfixOf` rendered) ["渦モデル", "θ", "係数", "生の補助関数"])
  assert "exact rational survives"
    (case parseFEProgram rendered of
       Right decoded -> containsExact (-7) 13 decoded
       Left _ -> False)

  let profile = feProgramDiscretization program
      reorderedWithNewOrigins = profile
        { discretizationDerivativeRules = reverse
            [rule { derivativeRuleOrigin = OriginId 99 }
            | rule <- discretizationDerivativeRules profile]
        }
      reordered = profile
        { discretizationDerivativeRules = reverse
            (discretizationDerivativeRules profile)
        }
  assert "profile fingerprint ignores rule source order and origin"
    (computeProfileFingerprint profile == computeProfileFingerprint reorderedWithNewOrigins)
  assert "set profile fingerprint verifies"
    (profileFingerprintMatches (setProfileFingerprint reorderedWithNewOrigins))

  let canonicalProgram = program
        { feProgramStepActions = [BindValue (NodeId 1)
            (ScalarValue canonicalStressScalar) (OriginId 2)]
        }
      unsortedProgram = canonicalProgram
        { feProgramDiscretization = setProfileFingerprint reordered
        , feProgramOrigins = reverseOrigins (feProgramOrigins canonicalProgram)
        , feProgramProvenance = reverseProvenance (feProgramProvenance canonicalProgram)
        , feProgramStepActions = [BindValue (NodeId 1)
            (ScalarValue unsortedStressScalar) (OriginId 2)]
        }
  assert "associations, Add/Mul, attributes, and multi-index encode canonically"
    (renderFEProgram canonicalProgram == renderFEProgram unsortedProgram)

  assertDecodeError "unknown top-level field" "unknown field"
    (decodeFEProgram (appendTopField "mystery" (Atom "x") encoded))
  assertDecodeError "missing top-level field" "missing field"
    (decodeFEProgram (removeTopField "mode" encoded))
  assertDecodeError "duplicate top-level field" "duplicate field"
    (decodeFEProgram (appendTopField "mode" (Atom "collocated") encoded))
  assertDecodeError "unknown top-level tag" "unknown top-level tag"
    (decodeFEProgram (replaceTopTag "not-feir" encoded))
  assertDecodeError "unknown FEIR version" "unsupported FEIR version"
    (decodeFEProgram (replaceVersion 2 encoded))
  assertDecodeError "profile fingerprint tampering" "fingerprint mismatch"
    (decodeFEProgram (tamperFingerprint encoded))

  putStrLn "feir codec tests: ok"

fixtureProgram :: FEProgram
fixtureProgram =
  FEProgram
    { feProgramVersion = 1
    , feProgramModel = ModelIdentity
        (ModelId "model:渦") "渦モデル"
        (SourceIdentity sourceId "/tmp/テンソル/渦.fme")
    , feProgramRegistryId = RegistryId "sha256:registry"
    , feProgramPrimitiveManifestId = PrimitiveManifestId "formurae-primitives@1"
    , feProgramDiscretization = fixtureProfile
    , feProgramMode = CollocatedMode
    , feProgramDimension = 2
    , feProgramAxes =
        [ AxisDecl (AxisId 1) "r" "x" (OriginId 1)
        , AxisDecl (AxisId 2) "θ" "y" (OriginId 1)
        ]
    , feProgramGeometry = fixtureGeometry
    , feProgramParameters =
        [ParameterDecl (ParamId 1) "係数" "coef" "1.0 / 3.0" (OriginId 1)]
    , feProgramFunctions =
        [ FunctionDecl (FunctionId 1) "sin" "sin" (Just 1) IntrinsicFunction Nothing
        , FunctionDecl (FunctionId 2) "potential" "potential" (Just 2)
            AnalyticFunction (Just (OriginId 2))
        , FunctionDecl (FunctionId 3) "external" "external" Nothing
            ExternalFunction (Just (OriginId 2))
        ]
    , feProgramFields = fixtureFields
    , feProgramInitializers =
        [ AnalyticInitializer (FEEquation (EquationId 1)
            (WholeFieldTarget (FieldId 1) CurrentTime)
            (scalarTensor (AnalyticCall (FunctionId 2)
              [Coordinate (AxisId 1), Coordinate (AxisId 2)]))
            (OriginId 2))
        , RawInitializer
            (FieldComponentTarget (FieldId 2) CurrentTime (Basis [1]))
            "sin(θ)\n" (OriginId 2)
        ]
    , feProgramStepActions =
        [ BindValue (NodeId 1) (ScalarValue fixtureScalar) (OriginId 2)
        , Materialize (FieldId 3) (ScalarValue (Ref (NodeId 1))) (OriginId 2)
        , UpdateField (FEEquation (EquationId 2)
            (WholeFieldTarget (FieldId 1) NextTime)
            (scalarTensor fixtureScalar) (OriginId 2))
        ]
    , feProgramRawHelpers =
        [RawHelper (RawHelperId 1) "extern function :: 生の補助関数" (OriginId 1)]
    , feProgramOrigins = OriginTable
        [(OriginId 1, sourceOrigin1), (OriginId 2, sourceOrigin2)]
    , feProgramProvenance = ProvenanceTable
        [(NodeId 1, [OriginId 1, OriginId 2]), (NodeId 2, [OriginId 2])]
    }

sourceId :: SourceId
sourceId = SourceId "source:渦"

location1, location2 :: SourceLocation
location1 = SourceLocation sourceId "/tmp/テンソル/渦.fme" 1 1 1 12
location2 = SourceLocation sourceId "/tmp/テンソル/渦.fme" 9 9 8 42

sourceOrigin1, sourceOrigin2 :: SourceOrigin
sourceOrigin1 = SourceOrigin location1 []
sourceOrigin2 = SourceOrigin location2
  [ExpansionFrame "Δ" location1 location2]

fixtureProfile :: DiscretizationProfile
fixtureProfile = setProfileFingerprint $ DiscretizationProfile
  (VersionedProfileId "formurae-discretization@1")
  (Fingerprint "pending")
  [ DerivativeRule CollocatedLattice Nothing CenteredTaylor
      (PositiveEven 2) (OriginId 1)
  , DerivativeRule CollocatedLattice (Just (Positive 2)) CenteredTaylor
      (PositiveEven 4) (OriginId 2)
  , DerivativeRule StaggeredLattice Nothing Yee
      (PositiveEven 2) (OriginId 1)
  ]
  FixedAxisOrder

fixtureFields :: [LogicalFieldDecl]
fixtureFields =
  [ LogicalFieldDecl (FieldId 1) "u" CollocatedPolicy
      (TensorType [] [] 0) ScalarLayout [] UserStateLifetime (OriginId 1)
  , LogicalFieldDecl (FieldId 2) "E" PrimalPolicy
      (TensorType [2] [VarianceDown] 0) VectorLayout
      [Just VarianceDown] UserStateLifetime (OriginId 1)
  , LogicalFieldDecl (FieldId 3) "flux" CollocatedPolicy
      (TensorType [] [] 0) ScalarLayout [] StepLocalLifetime (OriginId 2)
  ]

fixtureGeometry :: GeometryDecl
fixtureGeometry = GeometryDecl (GeometryId 1) (Just "g") (Just (OriginId 1))
  (EmbeddedOrthogonalGeometry
    [ Coordinate (AxisId 1)
    , Intrinsic (FunctionId 1) [Coordinate (AxisId 2)]
    ]
    geometryNF)
  where
    geometryNF = GeometryNF identityTensor identityTensor
      [ (AxisId 1, Exact 1 1)
      , (AxisId 2, Intrinsic (FunctionId 1) [Coordinate (AxisId 2)])
      ]
      (Intrinsic (FunctionId 1) [Coordinate (AxisId 2)]) True

identityTensor :: TensorNF
identityTensor = TensorNF [2, 2] [VarianceDown, VarianceDown] 0
  [ (Basis [1, 1], Exact 1 1)
  , (Basis [1, 2], Exact 0 1)
  , (Basis [2, 1], Exact 0 1)
  , (Basis [2, 2], Exact 1 1)
  ]

scalarTensor :: ScalarNF -> TensorNF
scalarTensor scalar = TensorNF [] [] 0 [(Basis [], scalar)]

fixtureJet :: FieldJet
fixtureJet = FieldJetValue (FieldId 2) CurrentTime (Basis [1])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)]
  [(AxisId 1, 2), (AxisId 2, 1)]

fixtureOpaque :: OpaqueDiscrete
fixtureOpaque = OpaqueDiscreteCall
  (VersionedOpId "lb.orthogonal@1") (SemanticKey "lb-key-17")
  (RequestGroupId "lb17") (Basis [])
  [ ScalarValue (FieldJet fixtureJet)
  , TensorValue (scalarTensor (Exact 1 2))
  ]
  fixtureAttributes

fixtureAttributes :: [Attribute]
fixtureAttributes =
  [ Attribute (AttributeId "01-exact") (AttributeExact 1 2)
  , Attribute (AttributeId "02-natural") (AttributeNatural 3)
  , Attribute (AttributeId "03-integer") (AttributeInteger (-4))
  , Attribute (AttributeId "04-boolean") (AttributeBoolean True)
  , Attribute (AttributeId "05-string") (AttributeString "計量")
  , Attribute (AttributeId "06-axis") (AttributeAxis (AxisId 2))
  , Attribute (AttributeId "07-parameter") (AttributeParameter (ParamId 1))
  , Attribute (AttributeId "08-function") (AttributeFunction (FunctionId 2))
  , Attribute (AttributeId "09-field") (AttributeField (FieldId 1))
  , Attribute (AttributeId "10-geometry") (AttributeGeometry (GeometryId 1))
  , Attribute (AttributeId "11-policy") (AttributeGridPolicy PrimalPolicy)
  , Attribute (AttributeId "12-time") (AttributeTimeSlot CurrentTime)
  , Attribute (AttributeId "13-basis") (AttributeBasis (Basis [1]))
  , Attribute (AttributeId "14-values")
      (AttributeValues [AttributeString "x", AttributeInteger 2])
  ]

fixtureScalar :: ScalarNF
fixtureScalar = Add
  [ AnalyticCall (FunctionId 2) [Coordinate (AxisId 1), Exact 1 2]
  , Coordinate (AxisId 2)
  , Div (Exact 1 1) (Parameter (ParamId 1))
  , Exact (-7) 13
  , FieldJet fixtureJet
  , Intrinsic (FunctionId 1) [Coordinate (AxisId 2)]
  , OpaqueDiscrete fixtureOpaque
  , Parameter (ParamId 1)
  , Pow (Coordinate (AxisId 1)) (Exact 2 1)
  , Ref (NodeId 2)
  , Select fixturePredicate
      (Mul [Exact 2 1, FieldJet fixtureJet])
      (Exact 0 1)
  ]

fixturePredicate :: PredicateNF
fixturePredicate = And
  [ BoolExact True
  , Compare CompareLe (Coordinate (AxisId 1)) (Exact 10 1)
  , Not (Or
      [ BoolExact False
      , Compare CompareNe (Parameter (ParamId 1)) (Exact 0 1)
      ])
  ]

canonicalStressScalar, unsortedStressScalar :: ScalarNF
canonicalStressScalar = Add
  [ Exact 1 1
  , FieldJet fixtureJet
  , OpaqueDiscrete fixtureOpaque
  ]
unsortedStressScalar = Add
  [ OpaqueDiscrete fixtureOpaque
      { opaqueDiscreteAttributes = reverse fixtureAttributes
      , opaqueDiscreteOperands =
          [ScalarValue (FieldJet fixtureJet
            { fieldJetMultiIndex = reverse (fieldJetMultiIndex fixtureJet) })
          , TensorValue (scalarTensor (Exact 1 2))
          ]
      }
  , FieldJet fixtureJet
      { fieldJetMultiIndex = reverse (fieldJetMultiIndex fixtureJet) }
  , Exact 1 1
  ]

reverseOrigins :: OriginTable -> OriginTable
reverseOrigins (OriginTable entries) = OriginTable (reverse entries)

reverseProvenance :: ProvenanceTable -> ProvenanceTable
reverseProvenance (ProvenanceTable entries) =
  ProvenanceTable (reverse [(nodeId, reverse origins) | (nodeId, origins) <- entries])

containsExact :: Integer -> Integer -> FEProgram -> Bool
containsExact numerator denominator program =
  ("(exact " ++ show numerator ++ " " ++ show denominator ++ ")")
  `isInfixOf` renderFEProgram program

appendTopField :: String -> SExpr -> SExpr -> SExpr
appendTopField name value (List values) = List (values ++ [List [Atom name, value]])
appendTopField _ _ expression = expression

removeTopField :: String -> SExpr -> SExpr
removeTopField name (List values) = List (filter (not . isNamedField name) values)
removeTopField _ expression = expression

isNamedField :: String -> SExpr -> Bool
isNamedField name (List [Atom actual, _]) = name == actual
isNamedField _ _ = False

replaceTopTag :: String -> SExpr -> SExpr
replaceTopTag tag (List (_ : rest)) = List (Atom tag : rest)
replaceTopTag _ expression = expression

replaceVersion :: Int -> SExpr -> SExpr
replaceVersion version (List (tag : _ : rest)) = List (tag : Atom (show version) : rest)
replaceVersion _ expression = expression

tamperFingerprint :: SExpr -> SExpr
tamperFingerprint (List values) = List (map tamperTop values)
  where
    tamperTop (List [Atom "discretization", profile]) =
      List [Atom "discretization", tamperProfile profile]
    tamperTop value = value
    tamperProfile (List fields) = List (map tamperField fields)
    tamperProfile value = value
    tamperField (List [Atom "fingerprint", _]) =
      List [Atom "fingerprint", StringAtom "sha256:tampered"]
    tamperField value = value
tamperFingerprint expression = expression

assert :: String -> Bool -> IO ()
assert _ True = return ()
assert label False = fail label

assertRightEqual :: (Eq a, Show a) => String -> a -> Either CodecError a -> IO ()
assertRightEqual label expected result =
  case result of
    Right actual ->
      if actual == expected
        then return ()
        else fail (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
    Left err -> fail (label ++ ": " ++ show err)

assertDecodeError :: String -> String -> Either CodecError a -> IO ()
assertDecodeError label expected result =
  case result of
    Left err | expected `isInfixOf` codecErrorMessage err -> return ()
             | otherwise -> fail (label ++ ": unexpected error " ++ show err)
    Right _ -> fail (label ++ ": unexpectedly decoded malformed FEIR")
