{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE StandaloneDeriving #-}

module Control.Selective.Example.ISA.Simulate where

import Prelude hiding (mod, read, (!!))
import Data.List.NonEmpty (NonEmpty (..), (!!))
import qualified Control.Monad.State as S
import qualified Data.Map.Strict as Map
import Control.Selective
import Control.Selective.Free.Rigid
import Control.Selective.Example.ISA.Types
import Control.Selective.Example.ISA.Instruction

-- | Hijack mtl's MonadState constraint to include Selective
type MonadState s m = (Selective m, S.MonadState s m)

type RegisterBank = Map.Map Register Value

emptyRegisters :: RegisterBank
emptyRegisters = Map.fromList [(R0, 0), (R1, 0), (R2, 0), (R3, 0)]

-- | We model memory as a map from bytes to signed 16-bit words
type Memory = Map.Map Address Value

emptyMemory :: Memory
emptyMemory = Map.fromList $ zip [0..maxBound] (repeat 0)

initialiseMemory :: [(Address, Value)] -> Memory
initialiseMemory m =
    let blankMemory = Map.fromList $ zip [0..255] [0, 0..]
    in foldr (\(addr, value) acc -> Map.adjust (const value) addr acc) blankMemory m

type Flags = Map.Map Flag Value

emptyFlags :: Flags
emptyFlags = Map.fromList [(Zero, 0), (Overflow, 0), (Halted, 0)]

data ISAState = ISAState { registers :: RegisterBank
                         , memory    :: Memory
                         -- | Program counter
                         , pc        :: InstructionAddress
                         -- | Instruction register
                         , program   :: NonEmpty Instruction
                         , flags     :: Flags
                         } deriving Show

-- | Interpret the internal ISA effect in 'MonadState'
toState :: MonadState ISAState m => RW a -> m a
toState (Read k t) = t <$> case k of
    Reg r     -> (Map.! r   ) <$> S.gets registers
    Cell addr -> (Map.! addr) <$> S.gets memory
    Flag f    -> (Map.! f   ) <$> S.gets flags
    PC        -> S.gets pc
toState (Write k fv t) = case k of
    Reg r     -> do v <- runSelect toState fv
                    let step s = Map.insert r v (registers s)
                    S.state $ \s -> (t v, s { registers = step s })
    Cell addr -> do v <- runSelect toState fv
                    let step s = Map.insert addr v (memory s)
                    S.state $ \s -> (t v, s { memory = step s })
    Flag f    -> do v <- runSelect toState fv
                    let step s = Map.insert f v (flags s)
                    S.state $ \s -> (t v, s { flags = step s })
    PC        -> do v <- runSelect toState fv
                    S.state (\s -> (t v, s { pc = v }))

-- | Interpret a 'Program' in the state monad
runProgram :: ISA a -> ISAState -> (a, ISAState)
runProgram f s = S.runState (runSelect toState f) s

boot :: Program -> Memory -> ISAState
boot prog mem = ISAState { registers = emptyRegisters
                         , memory    = mem
                         , pc        = 0
                         , program   = fmap snd prog
                         , flags     = emptyFlags
                         }

executeInstruction :: MonadState ISAState m => m Value
executeInstruction = do
    s <- S.get
    -- fetch instruction
    let i = (program s) !! (fromIntegral $ pc s)
        (v, s') = S.runState (runSelect toState (semantics $ i)) s
    S.put (s' {pc = pc s' + 1})
    pure v
    -- -- fetch instruction
    -- ic <- read IC
    -- write IR (read (Prog ic))
    -- -- increment instruction counter
    -- write IC (pure $ ic + 1)
    -- -- read instruction register and execute the instruction
    -- i <- read IR
    -- instructionSemantics' i read write

simulate :: Int -> ISAState -> ISAState
simulate steps state
    | steps <= 0 = state
    | otherwise  = if halted then state else simulate (steps - 1) nextState
  where
    halted    = (/= 0) $ (Map.!) (flags state) Halted
    nextState = snd $ S.runState executeInstruction state