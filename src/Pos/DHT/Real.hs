{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module Pos.DHT.Real
       ( KademliaDHT
       , runKademliaDHT
       , KademliaDHTConfig(..)
       ) where

import           Control.Concurrent.STM    (STM, TVar, atomically, newTVar, readTVar,
                                            writeTVar)
import           Control.Monad.Catch       (MonadCatch, MonadMask, MonadThrow, finally,
                                            throwM)
import           Control.Monad.Trans.Class (MonadTrans)
import           Control.TimeWarp.Logging  (WithNamedLogger, logDebug, logError, logInfo,
                                            logWarning, usingLoggerName)
import           Control.TimeWarp.Rpc      (BinaryP (..), Binding (..), ListenerH (..),
                                            MonadDialog, MonadResponse,
                                            MonadTransfer (..), NetworkAddress,
                                            RawData (..), hoistRespCond, listenR,
                                            messageName, sendH, sendR)
import           Control.TimeWarp.Timed    (MonadTimed, ThreadId, fork, killThread)
import           Data.Binary               (Binary, decodeOrFail, encode)
import qualified Data.ByteString           as BS
import           Data.ByteString.Lazy      (fromStrict, toStrict)
import qualified Data.Cache.LRU            as LRU
import           Data.Hashable             (hash)
import           Data.Proxy                (Proxy (..))
import           Data.Text                 (Text)
import           Formatting                (int, sformat, shown, (%))
import qualified ListT                     as ListT
import qualified Network.Kademlia          as K
import           Pos.DHT                   (DHTData, DHTException (..), DHTKey,
                                            DHTMsgHeader (..), DHTNode (..),
                                            DHTNodeType (..),
                                            DHTResponseT (getDHTResponseT),
                                            ListenerDHT (..), MonadDHT (..),
                                            MonadMessageDHT (..),
                                            MonadResponseDHT (closeResponse),
                                            WithDefaultMsgHeader (..), defaultSendToNode,
                                            filterByNodeType, joinNetworkNoThrow,
                                            randomDHTKey, withDhtLogger)
import           Serokell.Util.Base64      (base64F)
import qualified STMContainers.Map         as STM
import           Universum                 hiding (finally, fromStrict, killThread,
                                            toStrict)

toBSBinary :: Binary b => b -> BS.ByteString
toBSBinary = toStrict . encode

fromBSBinary :: Binary b => BS.ByteString -> Either [Char] (b, BS.ByteString)
fromBSBinary bs = case decodeOrFail $ fromStrict bs of
                Left (_, _, errMsg)  -> Left errMsg
                Right (rest, _, res) -> Right (res, toStrict rest)

instance K.Serialize DHTData where
  toBS = toBSBinary
  fromBS = fromBSBinary

instance K.Serialize DHTKey where
  toBS = toBSBinary
  fromBS = fromBSBinary

type DHTHandle = K.KademliaInstance DHTKey DHTData

data KademliaDHTContext m = KademliaDHTContext
    { kdcHandle               :: DHTHandle
    , kdcKey                  :: DHTKey
    , kdcMsgThreadId          :: TVar (Maybe (ThreadId (KademliaDHT m)))
    , kdcInitialPeers_        :: [DHTNode]
    , kdcListenByBinding      :: Binding -> KademliaDHT m ()
    , kdcStopped              :: TVar Bool
    -- TODO temporary code, to remove (after TW-47)
    , kdcOutboundListeners    :: STM.Map NetworkAddress (ThreadId (KademliaDHT m))
    , kdcNoCacheMessageNames_ :: [Text]
    }

data KademliaDHTConfig m = KademliaDHTConfig
    { kdcPort                :: Word16
    , kdcListeners           :: [ListenerDHT (KademliaDHT m)]
    , kdcMessageCacheSize    :: Int
    , kdcEnableBroadcast     :: Bool
    , kdcKeyOrType           :: Either DHTKey DHTNodeType
    , kdcInitialPeers        :: [DHTNode]
    , kdcNoCacheMessageNames :: [Text]
    }

newtype KademliaDHT m a = KademliaDHT { unKademliaDHT :: ReaderT (KademliaDHTContext m) m a }
    deriving (Functor, Applicative, Monad, MonadThrow, MonadCatch, MonadIO,
             MonadMask, WithNamedLogger, MonadTimed, MonadDialog p, MonadResponse)

instance MonadTransfer m => MonadTransfer (KademliaDHT m) where
    sendRaw addr req = lift $ sendRaw addr req
    listenRaw binding sink =
        KademliaDHT $ listenRaw binding $ hoistRespCond unKademliaDHT sink
    close = lift . close

instance (MonadIO m, WithNamedLogger m) => WithDefaultMsgHeader (KademliaDHT m) where
  defaultMsgHeader msg = do
      noCacheNames <- KademliaDHT $ asks kdcNoCacheMessageNames_
<<<<<<< HEAD
      pure . SimpleHeader . isJust . find ((==) . messageName $ proxyOf msg) $ noCacheNames
=======
      let header = SimpleHeader . isJust . find ((==) . messageName $ proxyOf msg) $ noCacheNames
      logDebug $ sformat ("Preparing message " % shown % ": header " % shown) (messageName $ proxyOf msg) header
      pure $ put header
>>>>>>> [POS-31] Add RequestBlock to nonCache message names + improve logging

proxyOf :: a -> Proxy a
proxyOf _ = Proxy

instance MonadTrans KademliaDHT where
  lift = KademliaDHT . lift

type instance ThreadId (KademliaDHT m) = ThreadId m

runKademliaDHT
    :: (WithNamedLogger m, MonadIO m, MonadTimed m, MonadDialog BinaryP m, MonadMask m)
    => KademliaDHTConfig m -> KademliaDHT m a -> m a
runKademliaDHT kdc@(KademliaDHTConfig {..}) action = startDHT kdc >>= runReaderT (unKademliaDHT action')
  where
    action' = (startMsgThread >> action'') `finally` stopDHT
    action'' = do
      joinNetworkNoThrow kdcInitialPeers
      action
    startMsgThread = do
      (tvar, listenByBinding) <- KademliaDHT $ (,) <$> asks kdcMsgThreadId <*> asks kdcListenByBinding
      tId <- fork . listenByBinding $ AtPort kdcPort
      liftIO . atomically $ writeTVar tvar (Just tId)

stopDHT :: (MonadTimed m, MonadIO m) => KademliaDHT m ()
stopDHT = do
    (kdcH, threadTV, outMap, stoppedTV) <- KademliaDHT $ (,,,)
            <$> asks kdcHandle
            <*> asks kdcMsgThreadId
            <*> asks kdcOutboundListeners
            <*> asks kdcStopped
    liftIO . atomically $ writeTVar stoppedTV True
    liftIO $ K.close kdcH
    mThreadId <- liftIO . atomically $ do
      tId <- readTVar threadTV
      writeTVar threadTV Nothing
      pure tId
    case mThreadId of
      Just tid -> killThread tid
      _        -> pure ()
    outThreads <- liftIO $ atomically $ ListT.toList (STM.stream outMap) <* STM.deleteAll outMap
    mapM_ killThread $ map snd outThreads

startDHT :: (MonadTimed m, MonadIO m, MonadDialog BinaryP m, WithNamedLogger m, MonadCatch m) => KademliaDHTConfig m -> m (KademliaDHTContext m)
startDHT KademliaDHTConfig {..} = do
    kdcKey <- either pure randomDHTKey kdcKeyOrType
    kdcHandle <-
        liftIO $
        K.createL
            (fromInteger . toInteger $ kdcPort)
            kdcKey
            (log' logDebug)
            (log' logError)
    kdcStopped <- liftIO . atomically $ newTVar False
    kdcMsgThreadId <- liftIO . atomically $ newTVar Nothing
    let kdcInitialPeers_ = kdcInitialPeers
    kdcOutboundListeners <- liftIO STM.newIO
    msgCache <- liftIO . atomically $ newTVar (LRU.newLRU (Just $ toInteger kdcMessageCacheSize) :: LRU.LRU Int ())
    let kdcListenByBinding =
          \binding -> do
                logInfo $ sformat ("Listening on binding " % shown) binding
<<<<<<< HEAD
                listenR binding (convert <$> kdcListeners) (rawListener kdcEnableBroadcast msgCache)
=======
                listenR binding get (convert <$> kdcListeners) (convert' $ rawListener kdcEnableBroadcast msgCache kdcStopped)
    logInfo $ sformat ("Launching Kademlia, noCacheMessageNames=" % shown) kdcNoCacheMessageNames
>>>>>>> [POS-31] Add RequestBlock to nonCache message names + improve logging
    let kdcNoCacheMessageNames_ = kdcNoCacheMessageNames
    pure $ KademliaDHTContext {..}
  where
    convert :: ListenerDHT m -> ListenerH BinaryP DHTMsgHeader m
    convert (ListenerDHT f) = ListenerH $ \(_, m) -> getDHTResponseT $ f m
    log' log =  usingLoggerName ("kademlia" <> "instance") . log . toText
    convert' handler = getDHTResponseT . handler

-- | Return 'True' if the message should be processed, 'False' if only
-- broadcasted
rawListener
    :: (WithDefaultMsgHeader m, MonadIO m, MonadThrow m, MonadDialog m, WithNamedLogger m, MonadMessageDHT m)
    => Bool -> TVar (LRU.LRU Int ()) -> TVar Bool -> (DHTMsgHeader, RawData) -> DHTResponseT m Bool
rawListener enableBroadcast cache kdcStopped (h, rawData@(RawData raw)) = withDhtLogger $ do
    isStopped <- liftIO . atomically $ readTVar kdcStopped
    when isStopped $ do
        closeResponse
        throwM $ FatalError "KademliaDHT stopped"
    let mHash = hash raw
    logDebug $
        sformat ("Received message " % shown % ", hash=" % int) h mHash
    ignoreMsg <- case h of
                   SimpleHeader True -> return False
                   _                 -> liftIO . atomically $ updCache cache mHash
    if ignoreMsg
       then logDebug $
                sformat ("Ignoring message " % shown % ", hash=" % int) h mHash
       else return ()
       -- Uncomment to dump messages:
       -- else logDebug $ sformat ("Message: hash=" % int % " bytes=" % base64F) mHash (toStrict $ encode rawData)


    -- If the message is in cache, we have already broadcasted it before, no
    -- need to do it twice
    when (not ignoreMsg && enableBroadcast) $
        case h of
            BroadcastHeader -> do
              logDebug $
                sformat ("Broadcasting message " % shown % ", hash=" % int) h mHash
              sendToNetworkR rawData
            SimpleHeader _  -> pure ()
    -- If the message wasn't in the cache, we want to process it too (not
    -- simply broadcast it)
    return (not ignoreMsg)

updCache :: TVar (LRU.LRU Int ()) -> Int -> STM Bool
updCache cacheTV dataHash = do
    cache <- readTVar cacheTV
    let (cache', mP) = dataHash `LRU.lookup` cache
    case mP of
      Just _ -> writeTVar cacheTV cache' >> pure True
      _      -> writeTVar cacheTV (LRU.insert dataHash () cache') >> pure False

-- TODO remove this code after TW-47 is done (!!)
registerOutboundHandler :: (MonadTimed m, MonadIO m) => NetworkAddress -> KademliaDHT m ()
registerOutboundHandler addr = do
    m <- KademliaDHT $ asks kdcOutboundListeners
    -- Here is possibility of race condition, but this code is temp solution
    mTid <- liftIO . atomically $ addr `STM.lookup` m
    case mTid of
      Just _ -> return ()
      Nothing -> do
        tid <- fork listenOutbound
        liftIO . atomically $ STM.insert tid addr m
  where
    listenOutbound = KademliaDHT (asks kdcListenByBinding) >>= ($ AtConnTo addr)

sendToNetworkR :: MonadDialog BinaryP m => RawData -> m ()
sendToNetworkR = sendToNetworkImpl sendR

sendToNetworkImpl :: (NetworkAddress -> DHTMsgHeader -> msg -> m ()) -> msg -> m ()
sendToNetworkImpl = notImplemented

instance (MonadDialog BinaryP m, WithNamedLogger m, MonadCatch m, MonadIO m, MonadTimed m)
       => MonadMessageDHT (KademliaDHT m) where
    sendToNetwork = sendToNetworkImpl sendH
    sendToNode addr msg = do
      registerOutboundHandler addr
      defaultSendToNode addr msg

instance (MonadIO m, MonadCatch m, WithNamedLogger m) => MonadDHT (KademliaDHT m) where

  joinNetwork [] = throwM AllPeersUnavailable
  joinNetwork nodes = do
      inst <- KademliaDHT $ asks kdcHandle
      asyncs <- mapM (liftIO . async . joinNetwork' inst) nodes
      waitAnyUnexceptional asyncs >>= handleRes
    where
      handleRes (Just _) = pure ()
      handleRes _        = throwM AllPeersUnavailable

  discoverPeers type_ = do
    inst <- KademliaDHT $ asks kdcHandle
    peers <- getKnownPeers
    when (null peers) $ do
      logWarning "Empty known peer list"
      init <- KademliaDHT $ asks kdcInitialPeers_
      joinNetworkNoThrow init
    _ <- liftIO $ K.lookup inst =<< randomDHTKey type_
    filterByNodeType type_ <$> getKnownPeers

  getKnownPeers = do
    myId <- currentNodeKey
    inst <- KademliaDHT $ asks kdcHandle
    filter (\n -> dhtNodeId n /= myId) . fmap toDHTNode <$> liftIO (K.dumpPeers inst)

  currentNodeKey = KademliaDHT $ asks kdcKey

  dhtLoggerName _ = "kademlia"

toDHTNode :: K.Node DHTKey -> DHTNode
toDHTNode n = DHTNode (fromKPeer . K.peer $ n) $ K.nodeId n

fromKPeer :: K.Peer -> NetworkAddress
fromKPeer (K.Peer {..}) = (show peerHost, fromIntegral peerPort)

toKPeer :: NetworkAddress -> K.Peer
toKPeer (peerHost, peerPort) = K.Peer (decodeUtf8 peerHost) (fromIntegral peerPort)

-- TODO add TimedIO, WithLoggerName constraints and uncomment logging
joinNetwork' :: (MonadIO m, MonadThrow m) => DHTHandle -> DHTNode -> m ()
joinNetwork' inst node = do
  let node' = K.Node (toKPeer $ dhtAddr node) (dhtNodeId node)
  res <- liftIO $ K.joinNetwork inst node'
  case res of
    K.JoinSucces -> pure ()
    K.NodeDown   -> throwM NodeDown
    K.IDClash    -> pure () --logInfo $ sformat ("joinNetwork: node " % build % " already contains us") node

-- TODO move to serokell-core ?
waitAnyUnexceptional :: (MonadIO m, WithNamedLogger m) => [Async a] -> m (Maybe (Async a, a))
waitAnyUnexceptional asyncs = liftIO (waitAnyCatch asyncs) >>= handleRes
  where
    handleRes (async', Right res) = pure $ Just (async', res)
    handleRes (async', Left e) = do
      logWarning $ sformat ("waitAnyUnexceptional: caught error " % shown) e
      if null asyncs'
         then pure Nothing
         else waitAnyUnexceptional asyncs'
      where asyncs' = filter (/= async') asyncs
