{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.MkClosure (mkClosure) where

import Data.Binary (encode)
import Language.Haskell.TH (Q, Exp, Name)
import Control.Distributed.Process.Internal.Types (Closure(Closure))
import Control.Distributed.Process.Internal.Closure.TH 
  ( mkStatic
  , functionSDict
  )
import Control.Distributed.Process.Internal.Closure.Static 
  ( staticCompose
  , staticDecode
  )

mkClosure :: Name -> Q Exp
mkClosure n = 
  [|   Closure ($(mkStatic n) `staticCompose` staticDecode $(functionSDict n)) 
     . encode
  |]
