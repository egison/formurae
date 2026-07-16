module Main where

import Data.List (isPrefixOf)

import Formurae.FEIR.Codec (parseFEProgram)
import Formurae.FEIR.Syntax

main :: IO ()
main = do
  input <- getContents
  encoded <- case reverse [line | line <- lines input, take 6 line == "(feir "] of
    line : _ -> pure line
    [] -> error "Egison output did not contain a canonical FEIR value"
  case parseFEProgram encoded of
    Left codecError -> error ("Egison FEIR did not parse: " ++ show codecError)
    Right program ->
      case derivativeJets (feProgramStepActions program) of
        [jet] | jet == expectedJet -> checkOpaque program
        [jet] -> error ("unexpected derivative FieldJet: " ++ show jet)
        jets -> error ("expected one derivative FieldJet, found: " ++ show jets)

checkOpaque :: FEProgram -> IO ()
checkOpaque program =
  case opaqueCalls (feProgramStepActions program) of
    [opaque]
      | opaqueDiscreteOpId opaque /= VersionedOpId "derivative.ordered@1" ->
          error ("unexpected opaque operation: " ++ show opaque)
      | opaqueDiscreteResultBasis opaque /= Basis [] ->
          error ("unexpected opaque result basis: " ++ show opaque)
      | opaqueDiscreteOperands opaque /= [ScalarValue (FieldJet baseJet)] ->
          error ("unexpected opaque operands: " ++ show opaque)
      | opaqueDiscreteAttributes opaque /= expectedOpaqueAttributes ->
          error ("unexpected opaque attributes: " ++ show opaque)
      | not ("feir-v1:" `isPrefixOf` semanticKeyText
          && "feir-v1-group:" `isPrefixOf` requestGroupText) ->
          error ("unexpected opaque keys: " ++ show opaque)
      | otherwise -> checkWide program
      where
        SemanticKey semanticKeyText = opaqueDiscreteSemanticKey opaque
        RequestGroupId requestGroupText = opaqueDiscreteRequestGroup opaque
    calls -> error ("expected one opaque call, found: " ++ show calls)

checkWide :: FEProgram -> IO ()
checkWide program =
  case wideCalls (feProgramStepActions program) of
    [opaque]
      | opaqueDiscreteOpId opaque
          /= VersionedOpId "derivative.coordinate-wide@1" ->
          error ("unexpected wide operation: " ++ show opaque)
      | opaqueDiscreteResultBasis opaque /= Basis []
          || opaqueDiscreteOperands opaque /= [ScalarValue (FieldJet baseJet)] ->
          error ("unexpected wide payload: " ++ show opaque)
      | opaqueDiscreteAttributes opaque /= expectedWideAttributes ->
          error ("unexpected wide attributes: " ++ show opaque)
      | otherwise -> checkGridWhole program
    calls -> error ("expected one wide call, found: " ++ show calls)

checkGridWhole :: FEProgram -> IO ()
checkGridWhole program =
  case gridWholeCalls (feProgramStepActions program) of
    [opaque]
      | opaqueDiscreteOpId opaque
          /= VersionedOpId "derivative.grid-whole@1" ->
          error ("unexpected grid-whole operation: " ++ show opaque)
      | opaqueDiscreteResultBasis opaque /= Basis [] ->
          error ("unexpected grid-whole result basis: " ++ show opaque)
      | opaqueDiscreteOperands opaque
          /= [ScalarValue expectedGridWholeOperand] ->
          error ("grid-whole operand was analytically distributed: " ++ show opaque)
      | opaqueDiscreteAttributes opaque /= expectedGridWholeAttributes ->
          error ("unexpected grid-whole attributes: " ++ show opaque)
      | otherwise -> putStrLn "Egison FieldJet/OpaqueDiscrete wire test: ok"
    calls -> error ("expected one grid-whole call, found: " ++ show calls)

derivativeJets :: [FEAction] -> [FieldJet]
derivativeJets actions =
  [ jet
  | BindValue (NodeId 3) (ScalarValue (FieldJet jet)) _ <- actions
  ]

opaqueCalls :: [FEAction] -> [OpaqueDiscrete]
opaqueCalls actions =
  [ opaque
  | BindValue (NodeId 4) (ScalarValue (OpaqueDiscrete opaque)) _ <- actions
  ]

wideCalls :: [FEAction] -> [OpaqueDiscrete]
wideCalls actions =
  [ opaque
  | BindValue (NodeId 5) (ScalarValue (OpaqueDiscrete opaque)) _ <- actions
  ]

gridWholeCalls :: [FEAction] -> [OpaqueDiscrete]
gridWholeCalls actions =
  [ opaque
  | BindValue (NodeId 6) (ScalarValue (OpaqueDiscrete opaque)) _ <- actions
  ]

expectedJet :: FieldJet
expectedJet = FieldJetValue
  (FieldId 1)
  CurrentTime
  (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)]
  [(AxisId 1, 1), (AxisId 2, 1)]

baseJet :: FieldJet
baseJet = FieldJetValue
  (FieldId 1)
  CurrentTime
  (Basis [])
  [Coordinate (AxisId 1), Coordinate (AxisId 2)]
  []

expectedOpaqueAttributes :: [Attribute]
expectedOpaqueAttributes =
  [ Attribute (AttributeId "order") (AttributeNatural 2)
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis (AxisId 1), AttributeAxis (AxisId 2)])
  , Attribute (AttributeId "radius") (AttributeNatural 1)
  ]

expectedWideAttributes :: [Attribute]
expectedWideAttributes =
  [ Attribute (AttributeId "order") (AttributeNatural 2)
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis (AxisId 2)])
  , Attribute (AttributeId "radius") (AttributeNatural 2)
  ]

expectedGridWholeOperand :: ScalarNF
expectedGridWholeOperand = Mul
  [ Exact 1 2
  , Pow (FieldJet baseJet) (Exact 2 1)
  ]

expectedGridWholeAttributes :: [Attribute]
expectedGridWholeAttributes =
  [ Attribute (AttributeId "order") (AttributeNatural 1)
  , Attribute (AttributeId "ordered-axes")
      (AttributeValues [AttributeAxis (AxisId 1)])
  , Attribute (AttributeId "radius") (AttributeNatural 1)
  ]
