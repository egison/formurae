module Formurae.Syntax where

import Data.Char (isAlpha, isAlphaNum, isSpace)

data Mode = CollocatedMode | DecMode
  deriving (Eq, Show)

data Kind = Scalar | Vector Bool | Form Int | SymM | AntiM | Tensor2 Bool
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
  , fdStaggered :: Bool
  , fdKind      :: Kind
  } deriving (Eq, Show)

data Init = IRaw String String | IVec String [String]
          | ISym String [String]
          | IAnti String [String]
          | ITensor2 String [String]
          | ICas String String
          | ICasIndex String [IxPart] String

data SK = KLet | KLocal | KEq deriving Eq

data Step = Step { sk :: SK, sNm :: String, sIdx :: [IxPart], sEx :: String }

data Def = Def
  { defName   :: String
  , defParams :: [String]
  , defBody   :: String
  } deriving (Eq, Show)

data Model = Model
  { mName   :: String
  , mDim    :: Int
  , mAxes   :: [String]
  , mMode   :: Maybe Mode
  , mMetricName :: Maybe String
  , mParams :: [(String, String)]
  , mHelp   :: [String]
  , mFlds   :: [(String, Kind)]
  , mFieldDecls :: [FieldDecl]
  , mInits  :: [Init]
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

data Elem = EId String Bool | EC Char | ERaw String | EMarkL String

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = lookup nm (mFlds m)

fieldDeclOf :: Model -> String -> Maybe FieldDecl
fieldDeclOf m nm =
  case [fd | fd <- mFieldDecls m, fdName fd == nm] of
    (fd:_) -> Just fd
    [] -> Nothing
