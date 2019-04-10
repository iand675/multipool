{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
module Data.MultiPool.Persist.Sql
    ( MultiPoolBackend(..)
    , unsafeRead
    ) where

import Control.Exception
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.MultiPool
import Data.Pool
import Database.Persist.Sql
import Database.Persist.Sql.Types.Internal
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM

instance MonadUnliftIO m => MultiPoolBackend m SqlBackend where
  type PrimaryConnection SqlBackend = SqlWriteBackend
  type ReplicaConnection SqlBackend = SqlReadBackend
  type ReplicaIdentifier SqlBackend = InstanceName SqlReadBackend

  runWriteAny b m = runWrite b () m
  runWrite b () m = runSqlPool m (multiPoolPrimary b)

  runReadPrimary b () m = runReadAnyPrimary b m
  runReadAnyPrimary b m = runSqlPool (readToWrite m) (multiPoolPrimary b)
  runReadAny b m = do
    mident <- liftIO $ multiPoolAnyReplicaSelector b b
    case mident of
      Nothing -> runReadAnyPrimary b m
      Just ident -> runRead b ident m
  runRead b ident m = case HM.lookup ident (multiPoolReplica b) of
    Nothing -> throw (InstanceDoesNotExist ident)
    Just repl -> runSqlPool m repl

  takePrimary b () = liftIO $ takeResource $ multiPoolPrimary b
  putPrimary _ l c = liftIO $ putResource l c

  takeReplica b ident = case HM.lookup ident (multiPoolReplica b) of
    Nothing -> throw (InstanceDoesNotExist ident)
    Just repl -> liftIO $ takeResource repl
  putReplica _ l c = liftIO $ putResource l c

unsafeRead :: ReaderT SqlBackend m a -> ReaderT SqlReadBackend m a
unsafeRead = withReaderT persistBackend
