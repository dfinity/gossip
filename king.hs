import Control.Monad
import Grapevine

main :: IO ()
main = do
  gv <- grapevineKing 4000
  putStrLn "Press Enter to publish peerage."
  void $ getLine
  publish gv
