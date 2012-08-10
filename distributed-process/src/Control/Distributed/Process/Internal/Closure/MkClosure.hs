{-# LANGUAGE TemplateHaskell #-}
module Control.Distributed.Process.Internal.Closure.MkClosure (mkClosure) where

import Data.Binary (encode)
import Language.Haskell.TH (Q, Exp, Name)
import Control.Distributed.Process.Internal.Closure.TH 
  ( mkStatic
  , functionSDict
  )
import Control.Distributed.Static (Closure(Closure), staticCompose)
import Control.Distributed.Process.Internal.Closure.BuiltIn (staticDecode)

{-
-- import Control.Distributed.Process.Internal.Types (Closure(Closure))
import Control.Distributed.Process.Internal.Closure.Static 
  ( staticCompose
  , staticDecode
  )
-}

-- | Create a closure
--
-- If @f : T1 -> T2@ is a /monomorphic/ function 
-- then @$(mkClosure 'f) :: T1 -> Closure T2@.
-- Be sure to pass 'f' to
-- 'Control.Distributed.Process.Internal.Closure.TH.remotable'. 
mkClosure :: Name -> Q Exp
mkClosure n = 
  [|   Closure ($(mkStatic n) `staticCompose` staticDecode $(functionSDict n)) 
     . encode
  |]
