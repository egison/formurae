module Formurae.Syntax where

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)

data Mode = CollocatedMode | DecMode
  deriving (Eq, Show)

data GridPolicy = Collocated | Primal | Dual
  deriving (Eq, Show)

data Kind = Scalar | Vector | Form Int | SymM | AntiM | Tensor2
  deriving (Eq, Show)

data FieldLayout =
    ScalarLayout
  | Rank1Layout
  | SymRank2Layout
  | AntiRank2Layout
  | FullRank2Layout
  deriving (Eq, Show)

data Variance = VUp | VDown deriving (Eq, Show)

data IxPart = IxPart Variance String deriving (Eq, Show)

data IndexGroup =
    Plain [IxPart]
  | Symmetric [IxPart]
  | Antisymmetric [IxPart]
  deriving (Eq, Show)

data FieldIndex = FieldIndex { fiGroups :: [IndexGroup] } deriving (Eq, Show)

data FieldDecl = FieldDecl
  { fdName      :: String
  , fdIndex     :: Maybe FieldIndex
  , fdLayout    :: FieldLayout
  , fdPolicy    :: GridPolicy
  , fdKind      :: Kind
  } deriving (Eq, Show)

data Init = IRaw String String | IVec String [String]
          | ISym String [String]
          | IAnti String [String]
          | ITensor2 String [String]
          | ICas String String
          | ICasIndex String [IxPart] String

data SK = KLet | KLocal | KEq deriving Eq

-- One expression as it appeared in the original .fme source and after
-- transliteration.  Each character in `sourceTranslated` has a 1-based
-- offset into `sourceOriginal`; multi-character transliterations therefore
-- map back to the single source character that produced them.
data SourceText = SourceText
  { sourcePath       :: FilePath
  , sourceLine       :: Int
  , sourceColumn     :: Int
  , sourceOriginal   :: String
  , sourceTranslated :: String
  , sourceOffsetMap  :: [Int]
  } deriving (Eq, Show)

data Step = Step
  { sk :: SK
  , sNm :: String
  , sIdx :: [IxPart]
  , sEx :: String
  , sSourceText :: SourceText
  }

data Def = Def
  { defName   :: String
  , defParams :: [String]
  , defBody   :: String
  , defSourceText :: Maybe SourceText
  } deriving (Eq, Show)

data Model = Model
  { mName   :: String
  , mSourcePath :: FilePath
  , mDim    :: Int
  , mAxes   :: [String]
  , mMode   :: Maybe Mode
  , mMetricName :: Maybe String
  , mParams :: [(String, String)]
  , mHelp   :: [String]
  , mFlds   :: [(String, Kind)]
  , mFieldDecls :: [FieldDecl]
  , mInits  :: [Init]
  , mInitSourceTexts :: [SourceText]
  , mSteps  :: [Step]
  , mDd     :: Maybe String
  , mMetric :: Maybe [String]
  , mEmbed  :: Maybe [String]
  , mDefs   :: [Def]
  }

selectedMode :: Model -> Mode
selectedMode m =
  case mMode m of
    Just mode -> mode
    Nothing -> error "selectedMode: mode declaration has not been validated"

modeSurfaceName :: Mode -> String
modeSurfaceName CollocatedMode = "collocated"
modeSurfaceName DecMode = "dec"

gridPolicySurfaceName :: GridPolicy -> String
gridPolicySurfaceName Collocated = "collocated"
gridPolicySurfaceName Primal = "primal"
gridPolicySurfaceName Dual = "dual"

-- Generated scalar binding used as the collocated result of a structural
-- Laplace--Beltrami backend request.  Keeping the name here lets placement
-- inference and emission share the same reserved identity.
lbResultBindingName :: String
lbResultBindingName = "feLbResult"

isLbResultBindingName :: String -> Bool
isLbResultBindingName name =
  case splitAt (length lbResultBindingName) name of
    (prefix, suffix) ->
      prefix == lbResultBindingName
      && (null suffix || all isDigit suffix)

data Tok = TId String Bool | TC Char

tokenize :: String -> [Tok]
tokenize [] = []
tokenize (c:cs)
  | isAlpha c =
      let (a, b) = span isWordChar cs
      in case b of
           ('\'':b') -> TId (c : a) True : tokenize b'
           _ -> TId (c : a) False : tokenize b
  | otherwise = TC c : tokenize cs
  where
    isWordChar ch = isAlphaNum ch || ch == '_'

untok :: [Tok] -> String
untok = concatMap out
  where
    out (TId nm pr) = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

isSpTok :: Tok -> Bool
isSpTok (TC c) = isSpace c
isSpTok _ = False

-- collect tokens up to the ')' closing an already-consumed '('
closeParenT :: Int -> [Tok] -> [Tok] -> Maybe ([Tok], [Tok])
closeParenT _ [] _ = Nothing
closeParenT n (TC '(' : ts) acc = closeParenT (n + 1) ts (TC '(' : acc)
closeParenT n (TC ')' : ts) acc
  | n == 1 = Just (reverse acc, ts)
  | otherwise = closeParenT (n - 1) ts (TC ')' : acc)
closeParenT n (t : ts) acc = closeParenT n ts (t : acc)

data Elem = EId String Bool | EC Char

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = lookup nm (mFlds m)

fieldDeclOf :: Model -> String -> Maybe FieldDecl
fieldDeclOf m nm =
  case [fd | fd <- mFieldDecls m, fdName fd == nm] of
    (fd:_) -> Just fd
    [] -> Nothing

fieldPolicyOf :: Model -> String -> GridPolicy
fieldPolicyOf m nm =
  case fieldDeclOf m nm of
    Just fd -> fdPolicy fd
    Nothing -> Collocated
