{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}

module Data.MultiPool.PostgreSQLSimple
    ( MultiPoolBackend(..)
    , initMultiPool
    , initMultiPool'
    ) where

import Control.Exception
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Data.ByteString.Char8 (ByteString)
import Data.Pool
import Data.MultiPool
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Database.PostgreSQL.Simple

initMultiPool ::
     (MonadUnliftIO m)
  => ByteString
  -> Int
  -> [(InstanceName Connection, ByteString, Int)]
  -> m (MultiPool Connection)
initMultiPool mc mn rl = do
  rr <- roundRobin $ map (\(i, _, _) -> i) rl
  initMultiPool' rr mc mn rl

initMultiPool' ::
     (MonadUnliftIO m)
  => (MultiPool Connection -> IO (Maybe (InstanceName Connection))) -- Strategy for selectin the replica instance when calling 'runReadAny'. 'roundRobin' is the current default.
  -> ByteString -- ^ Primary connection string
  -> Int -- ^ Max number of connections to master instance
  -> [(InstanceName Connection, ByteString, Int)] -- ^ Replica connection details
  -> m (MultiPool Connection)
initMultiPool' multiPoolAnyReplicaSelector str n is = do
  multiPoolPrimary <- liftIO $ createPool (connectPostgreSQL str) close n 15 1
  replicas <- liftIO $ mapM (\(inst, connStr, numConns) -> (,) <$> pure inst <*> createPool (connectPostgreSQL connStr) close numConns 15 1) is
  let multiPoolReplica = HM.fromList replicas
      multiPoolAnyPrimarySelector = const $ pure ()
  return $ MultiPool {..}

withResource' :: MonadUnliftIO m => Pool a -> (a -> m b) -> m b
withResource' pool action =
  withRunInIO $ \io ->
    liftIO $ withResource pool $ \a ->
      io $ action a

instance MonadUnliftIO m => MultiPoolBackend m Connection where
  type PrimaryConnection Connection = Connection
  type ReplicaConnection Connection = Connection
  type ReplicaIdentifier Connection = InstanceName Connection

  runWriteAny b m = runWrite b () m
  runWrite b () m = withResource' (multiPoolPrimary b) $ runReaderT m

  runReadPrimary b () m = runReadAnyPrimary b m
  runReadAnyPrimary b m = withResource' (multiPoolPrimary b) $ runReaderT m
  runReadAny b m = do
    mident <- liftIO $ multiPoolAnyReplicaSelector b b
    case mident of
      Nothing -> runReadAnyPrimary b m
      Just ident -> runRead b ident m
  runRead b ident m = case HM.lookup ident (multiPoolReplica b) of
    Nothing -> throw (InstanceDoesNotExist ident)
    Just repl -> withResource' repl $ runReaderT m

  takePrimary b () = liftIO $ takeResource $ multiPoolPrimary b
  putPrimary _ l c = liftIO $ putResource l c

  takeReplica b ident = case HM.lookup ident (multiPoolReplica b) of
    Nothing -> throw (InstanceDoesNotExist ident)
    Just repl -> liftIO $ takeResource repl
  putReplica _ l c = liftIO $ putResource l c
