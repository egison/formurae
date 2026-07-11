module Main where

import Control.Monad (unless)

import Formurae.FEIR.Fingerprint (sha256Utf8)

main :: IO ()
main = do
  assertEqual
    "empty"
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (sha256Utf8 "")
  assertEqual
    "abc"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (sha256Utf8 "abc")
  -- The UTF-8 bytes for U+03C0 are CF 80.  This vector catches accidental
  -- hashing of Haskell Char code points or platform-local encodings.
  assertEqual
    "UTF-8"
    "2617fcb92baa83a96341de050f07a3186657090881eae6b833f66a035600f35a"
    (sha256Utf8 "π")
  putStrLn "FEIR fingerprint tests: ok"

assertEqual :: String -> String -> String -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $ fail
    (label ++ ": expected " ++ expected ++ ", got " ++ actual)
