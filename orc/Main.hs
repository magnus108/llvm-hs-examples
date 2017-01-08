{-# LANGUAGE ForeignFunctionInterface #-}

module Main where

import LLVM.General.AST
import LLVM.General.AST.Constant
import qualified LLVM.General.AST as AST
import LLVM.General.AST.Global
import LLVM.General.Context
import LLVM.General.Module
import LLVM.General.Target

import LLVM.General.OrcJIT
import LLVM.General.OrcJIT.IRCompileLayer (IRCompileLayer, withIRCompileLayer)
import qualified LLVM.General.OrcJIT.IRCompileLayer as IRCompileLayer
import qualified LLVM.General.OrcJIT.CompileOnDemandLayer as CODLayer

import Control.Monad.Except

import Data.Int
import Data.Word
import Foreign.Ptr

foreign import ccall "dynamic"
  mkMain :: FunPtr (IO Int32) -> IO Int32

int :: Type
int = IntegerType 32

defAdd :: Definition
defAdd = GlobalDefinition functionDefaults
  { name = Name "add"
  , parameters = ( [] , False )
  , returnType = int
  , basicBlocks = [body]
  }
  where
    body = BasicBlock
        (Name "entry")
        []
        (Do $ Ret (Just (ConstantOperand (Int 32 42))) [])


module_ :: AST.Module
module_ = defaultModule
  { moduleName = "basic"
  , moduleDefinitions = [defAdd]
  }

withTestModule :: AST.Module -> (LLVM.General.Module.Module -> IO a) -> IO (Either String a)
withTestModule mod f = withContext $ \context -> runExceptT (withModuleFromAST context mod f)

resolver :: MangledSymbol -> IRCompileLayer -> MangledSymbol -> IO JITSymbol
resolver testFunc compileLayer symbol
  = IRCompileLayer.findSymbol compileLayer symbol True

nullResolver :: MangledSymbol -> IO JITSymbol
nullResolver s = putStrLn "nullresolver" >> return (JITSymbol 0 (JITSymbolFlags False False))

failInIO :: ExceptT String IO a -> IO a
failInIO = either fail return <=< runExceptT

eagerJit :: AST.Module -> IO (Either String Int32)
eagerJit amod =
    withTestModule amod $ \mod ->
      failInIO $ withHostTargetMachine $ \tm ->
        withObjectLinkingLayer $ \objectLayer ->
          withIRCompileLayer objectLayer tm $ \compileLayer -> do
            asm <- moduleLLVMAssembly mod
            putStrLn asm
            testFunc <- IRCompileLayer.mangleSymbol compileLayer "add"
            IRCompileLayer.withModuleSet
              compileLayer
              [mod]
              (SymbolResolver (resolver testFunc compileLayer) nullResolver) $
              \moduleSet -> do
                mainSymbol <- IRCompileLayer.mangleSymbol compileLayer "add"
                JITSymbol mainFn _ <- IRCompileLayer.findSymbol compileLayer mainSymbol True
                result <- mkMain (castPtrToFunPtr (wordPtrToPtr mainFn))
                return result

main :: IO ()
main = do
  res <- eagerJit module_
  putStrLn "Eager JIT Result:"
  print res