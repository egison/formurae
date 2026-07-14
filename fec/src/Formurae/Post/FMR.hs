module Formurae.Post.FMR
  ( GridIndex(..)
  , FExpr(..)
  , AssignmentTarget(..)
  , FAssignment(..)
  , FProgram(..)
  , FMRError(..)
  , independentBases
  , storageName
  , storageNames
  , renderExpr
  , renderProgram
  ) where

import Data.List (intercalate)
import qualified Data.Ratio as Ratio

import Formurae.FEIR.Syntax

data GridIndex = GridIndex
  { gridIndexBase :: String
  , gridIndexOffset :: Rational
  } deriving (Eq, Ord, Show)

data FExpr
  = FExact Integer Integer
  | FNamedConstant NamedConstant
  | FVariable String
  | FGridReference String [GridIndex]
  | FAdd [FExpr]
  | FMul [FExpr]
  | FDiv FExpr FExpr
  | FPow FExpr FExpr
  | FCall String [FExpr]
  | FCompare CompareOp FExpr FExpr
  | FSelect FExpr FExpr FExpr
  | FRawExpr String
  deriving (Eq, Ord, Show)

data AssignmentTarget
  = InitialTarget String [String]
  | StepBindingTarget String
  | StepUpdateTarget String
  deriving (Eq, Ord, Show)

data FAssignment = FAssignment
  { fAssignmentTarget :: AssignmentTarget
  , fAssignmentExpr :: FExpr
  } deriving (Eq, Ord, Show)

data FProgram = FProgram
  { fProgramDimension :: Int
  , fProgramAxes :: [String]
  , fProgramParameters :: [(String, String)]
  , fProgramHelpers :: [String]
  , fProgramStateStorage :: [String]
  , fProgramInitializers :: [FAssignment]
  -- FEIR actions are sequential: a later local may read an earlier NextTime
  -- update, and a later update may in turn read that local.  Keep one stream
  -- so rendering cannot regroup bindings ahead of updates.
  , fProgramStepAssignments :: [FAssignment]
  } deriving (Eq, Ord, Show)

data FMRError
  = InvalidFMRDimension Int
  | InvalidFMRShape FieldId [Int]
  | InvalidFMRBasis FieldId Basis
  | InvalidFMRLayout FieldId Layout [Int]
  | InvalidDeclaredVarianceCount FieldId Int Int
  | InvalidExactDenominator Integer
  | EmptyFMRExpression String
  deriving (Eq, Ord, Show)

independentBases
    :: Int -> LogicalFieldDecl -> Either FMRError [Basis]
independentBases dimension field
  | dimension < 1 = Left (InvalidFMRDimension dimension)
  | otherwise =
      case (logicalFieldLayout field, tensorTypeShape tensorType) of
        (ScalarLayout, []) -> Right [Basis []]
        (VectorLayout, [extent])
          | extent == dimension -> Right [Basis [axis] | axis <- axes]
        (SymmetricLayout, [rows, columns])
          | rows == dimension && columns == dimension ->
              Right
                ( [Basis [axis, axis] | axis <- axes]
                  ++ [ Basis [row, column]
                     | row <- axes
                     , column <- [row + 1 .. dimension]
                     ]
                )
        (AntisymmetricLayout, [rows, columns])
          | rows == dimension && columns == dimension ->
              Right
                [ Basis [row, column]
                | row <- axes
                , column <- [row + 1 .. dimension]
                ]
        (FullLayout, shape)
          | all (== dimension) shape -> Right (map Basis (rowMajorBases shape))
        (FormLayout, shape)
          | length shape == tensorTypeDfOrder tensorType
          , all (== dimension) shape ->
              Right (map Basis (choose (tensorTypeDfOrder tensorType) axes))
        (layout, shape) ->
          Left (InvalidFMRLayout (logicalFieldId field) layout shape)
  where
    tensorType = logicalFieldTensorType field
    axes = [1 .. dimension]

storageNames :: Int -> LogicalFieldDecl -> Either FMRError [(Basis, String)]
storageNames dimension field = do
  bases <- independentBases dimension field
  mapM (\basis -> (,) basis <$> storageName field basis) bases

storageName :: LogicalFieldDecl -> Basis -> Either FMRError String
storageName field basis@(Basis indices) = do
  let declared = logicalFieldDeclaredVariances field
      rank = length (tensorTypeShape (logicalFieldTensorType field))
  if length indices /= rank
    then Left (InvalidFMRBasis (logicalFieldId field) basis)
    else if length declared /= rank
      then Left (InvalidDeclaredVarianceCount
        (logicalFieldId field) rank (length declared))
      else if and (zipWith inRange indices (tensorTypeShape tensorType))
        then Right (logicalFieldSourceName field
          ++ concat (zipWith indexTag declared indices))
        else Left (InvalidFMRBasis (logicalFieldId field) basis)
  where
    tensorType = logicalFieldTensorType field
    inRange index extent = index >= 1 && index <= extent
    indexTag Nothing index = "_" ++ show index
    indexTag (Just VarianceUp) index = "_up" ++ show index
    indexTag (Just VarianceDown) index = "_down" ++ show index

renderProgram :: FProgram -> Either FMRError String
renderProgram program
  | dimension < 1 || dimension > 3 = Left (InvalidFMRDimension dimension)
  | length (fProgramAxes program) /= dimension =
      Left (InvalidFMRDimension dimension)
  | otherwise = do
      initializerLines <- mapM (renderAssignment [])
        (fProgramInitializers program)
      stepLines <- mapM (renderAssignment gridIndices)
        (fProgramStepAssignments program)
      let state = fProgramStateStorage program
          primed = map (++ "'") state
          header =
            [ "dimension :: " ++ show dimension
            , "axes :: " ++ intercalate "," (fProgramAxes program)
            ]
          parameters =
            [ "double :: " ++ name ++ " = " ++ value
            | (name, value) <- fProgramParameters program
            ]
          initFunction =
            [ "begin function " ++ tuple state ++ " = init()"
            , "  double [] :: " ++ intercalate ", " state
            ]
            ++ map ("  " ++) initializerLines
            ++ ["end function"]
          stepFunction =
            [ "begin function " ++ tuple primed ++ " = step(" ++ intercalate "," state ++ ")" ]
            ++ map ("  " ++) stepLines
            ++ ["end function"]
          sections = filter (not . null)
            [ header
            , parameters
            , fProgramHelpers program
            , initFunction
            , stepFunction
            ]
      Right (intercalate "\n\n" (map unlinesWithoutFinal sections) ++ "\n")
  where
    dimension = fProgramDimension program
    gridIndices = take dimension ["i", "j", "k"]
    tuple [value] = value
    tuple values = "(" ++ intercalate "," values ++ ")"

-- Formura binds coordinate indices from an indexed assignment target.  Field
-- references such as u[i,j] do not bind `i`/`j` for a separate coordinate
-- expression, so every grid-valued step binding and update must carry the
-- target indices explicitly (for example u'[i,j] = dx*i + ...).
renderAssignment :: [String] -> FAssignment -> Either FMRError String
renderAssignment stepIndices assignment = do
  expression <- renderExpr (fAssignmentExpr assignment)
  let target =
        case fAssignmentTarget assignment of
          InitialTarget name indices ->
            name ++ "[" ++ intercalate "," indices ++ "]"
          StepBindingTarget name -> indexed name
          StepUpdateTarget name -> indexed (name ++ "'")
  Right (target ++ " = " ++ expression)
  where
    indexed name = name ++ "[" ++ intercalate "," stepIndices ++ "]"

renderExpr :: FExpr -> Either FMRError String
renderExpr expression = renderAt 0 expression

renderAt :: Int -> FExpr -> Either FMRError String
renderAt parentPrecedence expression =
  case expression of
    FExact numerator denominator
      | denominator <= 0 -> Left (InvalidExactDenominator denominator)
      | denominator == 1 && numerator < 0 -> Right ("(" ++ show numerator ++ ")")
      | denominator == 1 -> Right (show numerator)
      | otherwise -> Right
          ("(" ++ show numerator ++ " / " ++ show denominator ++ ")")
    -- This exact rational is the IEEE-754 binary64 value of pi.  Keeping the
    -- node symbolic until rendering prevents surrounding coefficients (for
    -- example 19*pi/24) from being folded into integers above 2^53.
    FNamedConstant Pi ->
      Right "(884279719003555 / 281474976710656)"
    FVariable name -> Right name
    FGridReference name indices -> do
      renderedIndices <- mapM renderGridIndex indices
      Right (name ++ "[" ++ intercalate "," renderedIndices ++ "]")
    FAdd [] -> Left (EmptyFMRExpression "add")
    FAdd terms -> do
      rendered <- mapM (renderAt 40) terms
      parenthesize 40 parentPrecedence (intercalate " + " rendered)
    FMul [] -> Left (EmptyFMRExpression "mul")
    FMul factors -> do
      rendered <- mapM (renderAt 60) factors
      parenthesize 60 parentPrecedence (intercalate " * " rendered)
    FDiv numerator denominator -> do
      lhs <- renderAt 60 numerator
      rhs <- renderAt 61 denominator
      parenthesize 60 parentPrecedence (lhs ++ " / " ++ rhs)
    FPow base exponentValue -> do
      lhs <- renderAt 81 base
      rhs <- renderAt 80 exponentValue
      parenthesize 80 parentPrecedence (lhs ++ "**" ++ rhs)
    FCall name arguments -> do
      rendered <- mapM (renderAt 0) arguments
      Right (name ++ "(" ++ intercalate "," rendered ++ ")")
    FCompare operator lhs rhs -> do
      renderedLhs <- renderAt 31 lhs
      renderedRhs <- renderAt 31 rhs
      parenthesize 30 parentPrecedence
        (renderedLhs ++ " " ++ compareToken operator ++ " " ++ renderedRhs)
    FSelect condition yes no -> do
      renderedCondition <- renderAt 0 condition
      renderedYes <- renderAt 0 yes
      renderedNo <- renderAt 0 no
      parenthesize 20 parentPrecedence
        ("if " ++ renderedCondition ++ " then " ++ renderedYes ++ " else " ++ renderedNo)
    FRawExpr source -> Right source

renderGridIndex :: GridIndex -> Either FMRError String
renderGridIndex (GridIndex base offset)
  | offset == 0 = Right base
  | offset > 0 = Right (base ++ "+" ++ renderOffset offset)
  | otherwise = Right (base ++ "-" ++ renderOffset (abs offset))

renderOffset :: Rational -> String
renderOffset value
  | Ratio.denominator value == 1 = show (Ratio.numerator value)
  | otherwise = "(" ++ show (Ratio.numerator value) ++ " / "
                ++ show (Ratio.denominator value) ++ ")"

parenthesize :: Int -> Int -> String -> Either FMRError String
parenthesize precedence parentPrecedence rendered
  | precedence < parentPrecedence = Right ("(" ++ rendered ++ ")")
  | otherwise = Right rendered

compareToken :: CompareOp -> String
compareToken CompareEq = "=="
compareToken CompareNe = "!="
compareToken CompareLt = "<"
compareToken CompareLe = "<="
compareToken CompareGt = ">"
compareToken CompareGe = ">="

rowMajorBases :: [Int] -> [[Int]]
rowMajorBases [] = [[]]
rowMajorBases (extent : rest) =
  [ index : suffix
  | index <- [1 .. extent]
  , suffix <- rowMajorBases rest
  ]

choose :: Int -> [a] -> [[a]]
choose 0 _ = [[]]
choose _ [] = []
choose count (value : rest)
  | count < 0 = []
  | otherwise = map (value :) (choose (count - 1) rest) ++ choose count rest

unlinesWithoutFinal :: [String] -> String
unlinesWithoutFinal = intercalate "\n"
