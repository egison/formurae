module Formurae.Common where

import Data.Char (isAlpha, isAlphaNum, isSpace)
import Data.List (dropWhileEnd, isPrefixOf)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

fatal :: String -> IO a
fatal msg = hPutStrLn stderr ("pre-fec: error: " ++ msg) >> exitFailure

strip, rstrip :: String -> String
rstrip = dropWhileEnd isSpace
strip = dropWhile isSpace . rstrip

isW :: Char -> Bool
isW c = isAlphaNum c || c == '_'

stripComment :: String -> String
stripComment ('-':'-':_) = []
stripComment (c:cs) = c : stripComment cs
stripComment [] = []

reservedInternalPrefix :: String
reservedInternalPrefix = "FormuraeInternal"

isReservedInternalName :: String -> Bool
isReservedInternalName = isPrefixOf reservedInternalPrefix

rejectReservedName :: Int -> String -> IO ()
rejectReservedName ln nm =
  if isReservedInternalName nm
    then fatal ("identifier is reserved for generated code: " ++ nm
                ++ " (line " ++ show ln ++ ")")
    else return ()

validSurfaceName :: String -> Bool
validSurfaceName (c:cs) = isAlpha c && all isAlphaNum cs
validSurfaceName [] = False

splitOn :: Char -> String -> [String]
splitOn ch = foldr step [[]]
  where
    step c acc@(cur:rest) | c == ch = [] : acc
                          | otherwise = (c : cur) : rest
    step _ [] = [[]]

-- split on a separator at paren/bracket depth 0
splitTop :: Char -> String -> [String]
splitTop sep = go 0 []
  where
    go :: Int -> String -> String -> [String]
    go _ acc [] = [strip (reverse acc)]
    go d acc (c:cs)
      | c `elem` "([" = go (d + 1) (c : acc) cs
      | c `elem` ")]" = go (d - 1) (c : acc) cs
      | c == sep && d == 0 = strip (reverse acc) : go 0 [] cs
      | otherwise = go d (c : acc) cs
