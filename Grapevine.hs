{-# LANGUAGE OverloadedStrings #-}
module Grapevine (Grapevine, grapevineKing, grapevineNoble,
  grapevinePort, grapevineSize, grapevineTable,
  publish, yell, hear, getStats, putStats, htmlNetStats) where

import Data.ByteString.Char8 (ByteString, pack, unpack)
import qualified Data.ByteString.Char8 as B
import Control.Concurrent hiding (readChan)
import Control.Concurrent.BoundedChan as BChan
import Control.Exception
import Control.Monad
import qualified Crypto.Hash.SHA256 as SHA256
import Data.Char
import Data.IP
import Data.List.Split
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)
import Network.Socket hiding (send, recv)
import Safe
import System.IO

import Kautz

data Message = Hello String | Peerage Bool (M.Map String String)
  | Predecessor | Successor String | Edict ByteString deriving (Show, Read)

data Grapevine = Grapevine {
  myNetName :: String,
  myPort :: PortNumber,
  mySock :: Socket,
  blobChan :: BoundedChan ByteString,
  statsChan :: BoundedChan (String, ByteString),
  peerage :: MVar (M.Map String SockAddr),
  kingHandle :: Maybe Handle,
  neighbours :: MVar (M.Map String (BoundedChan ByteString, Handle)),
  netStats :: MVar (M.Map String Int),
  seenTables :: MVar [Set ByteString],
  isMeshed :: MVar Bool
}

newGrapevine :: String -> Int -> IO Grapevine
newGrapevine name port = do
  let sockAddr = SockAddrInet (fromIntegral port) iNADDR_ANY
  inSock <- socket AF_INET Stream 0
  setSocketOption inSock ReusePort 1
  bind inSock sockAddr
  listen inSock 128
  inPort <- socketPort inSock
  bc <- newBoundedChan 16384
  sc <- newBoundedChan 64
  emptyPeerage <- newMVar M.empty
  emptyNeighbours <- newMVar M.empty
  emptyNetStats <- newMVar M.empty
  emptySeens <- newMVar $ replicate 3 Set.empty
  meshedFalse <- newMVar False
  pure $ Grapevine {
    myNetName = name,
    myPort = inPort,
    mySock = inSock,
    blobChan = bc,
    statsChan = sc,
    peerage = emptyPeerage,
    kingHandle = Nothing,
    neighbours = emptyNeighbours,
    netStats = emptyNetStats,
    seenTables = emptySeens,
    isMeshed = meshedFalse
  }

putStats :: Grapevine -> ByteString -> IO ()
putStats gv stats = do
  status <- tryWriteChan (statsChan gv) ("", stats)
  when (not status) $ putStrLn "channel full: STATS DROPPED"

getStats :: Grapevine -> IO (String, ByteString)
getStats gv = if not $ isKing gv then ioError $ userError "BUG: only King calls getStats" else readChan $ statsChan gv

grapevineSize :: Grapevine -> IO Int
grapevineSize gv = M.size <$> readMVar (peerage gv)

grapevinePort :: Grapevine -> PortNumber
grapevinePort = myPort

grapevineKing :: String -> Int -> IO Grapevine
grapevineKing name port = do
  gv <- newGrapevine name port
  putStrLn $ "PORT = " ++ show (myPort gv)
  void $ forkIO $ kingLoop gv
  pure gv

-- | Open an outbound socket on the same socket we're listening on.
reuseMyPort :: Grapevine -> IO Socket
reuseMyPort gv = do
  outSock <- socket AF_INET Stream 0
  setSocketOption outSock ReusePort 1
  bind outSock $ SockAddrInet (myPort gv) iNADDR_ANY
  pure outSock

grapevineNoble :: String -> String -> Int -> IO Grapevine
grapevineNoble king name port = do
  let [host, seedPort] = splitOn ":" king
  gv0 <- newGrapevine name port
  addrInfo <- getAddrInfo Nothing (Just host) (Just seedPort)
  outSock <- reuseMyPort gv0
  connect outSock (addrAddress $ head addrInfo)
  h <- socketToHandle outSock ReadWriteMode
  let gv = gv0 { kingHandle = Just h }
  void $ forkIO $ nobleLoop gv
  void $ forkIO $ handshake gv h
  pure gv

handshake :: Grapevine -> Handle -> IO ()
handshake gv h = do
  -- 1. Say Hello.
  wire h $ pack $ show $ Hello $ myNetName gv
  -- 2. Read Peerage.
  Just (Peerage meshed m) <- readMay . unpack <$> procure h
  let Just ps = readPeerage m
  void $ swapMVar (peerage gv) ps
  print =<< readMVar (peerage gv)
  void $ swapMVar (isMeshed gv) meshed
  socialize gv
  -- 3. Say OK after meshing.
  wire h "OK"
  -- 4. Send stats.
  forever $ wire h . snd =<< readChan (statsChan gv)

-- | Slurp messages from a handle.
-- Counterpart to `stream`.
slurp :: Grapevine -> SockAddr -> Handle -> IO ()
slurp gv peer h = do
  let
    discon e = do
      add gv (-1) ("in/" ++ show peer ++ "/connected")
      putStrLn $ "DISCONNECT: " ++ show peer ++ ": " ++ show (e :: SomeException)
  inc gv ("in/" ++ show peer ++ "/connected")
  handle discon $ forever $ do
    process gv =<< procure h
    inc gv ("in/" ++ show peer ++ "/msg")

nobleLoop :: Grapevine -> IO ()
nobleLoop gv = forever $ do
  (sock, peer) <- accept $ mySock gv
  void $ forkIO $ do
    h <- socketToHandle sock ReadWriteMode
    bs <- procure h
    case readMay $ unpack bs of
      Just (Edict b) -> do  -- Only King sends these.
        process gv b
        yell gv b
      Just Predecessor -> slurp gv peer h
      Just (Successor s) -> do
        putStrLn $ "SUCCESSOR RECONNECT: " ++ show peer
        stream gv s h
      _ -> putStrLn "BAD GREETING"
    hClose h

kingLoop :: Grapevine -> IO ()
kingLoop gv = forever $ do
  (sock, peer) <- accept $ mySock gv
  void $ forkIO $ do
    h <- socketToHandle sock ReadWriteMode
    putStrLn $ show peer
    bs <- procure h
    case readMay $ unpack bs of
      Just (Hello s) -> do
        ps <- takeMVar $ peerage gv
        putMVar (peerage gv) $ M.insert s peer ps
        -- TODO: The following channel is unused. Perhaps we should
        -- have a King-specific neighbour handles list.
        -- After the first block, the King's only job is to collect stats.
        ch <- newBoundedChan 1
        ns <- takeMVar $ neighbours gv
        putMVar (neighbours gv) $ M.insert s (ch, h) ns
        alreadyMeshed <- readMVar $ isMeshed gv
        when (alreadyMeshed) $ sendAlreadyMeshedPeerage gv h
      _ -> putStrLn "BAD HELLO"

sendAlreadyMeshedPeerage :: Grapevine -> Handle -> IO ()
sendAlreadyMeshedPeerage gv h = do
  ps <- readMVar $ peerage gv
  wire h $ pack $ show $ Peerage True $ M.map show ps
  bs <- procure h
  when (bs /= "OK") $ ioError $ userError "EXPECT OK"

readPeerage :: M.Map String String -> Maybe (M.Map String SockAddr)
readPeerage m = Just $ M.map f m where
  f s = SockAddrInet (read port) host where
    [ip4, port] = splitOn ":" s
    host = toHostAddress $ read ip4

wire :: Handle -> ByteString -> IO ()
wire h s = do
  let n = B.length s
  when (n > 5 * 1024 * 1024) $ ioError $ userError "wire: artifact too large!"
  let ds = map (chr . (`mod` 256) . div n) $ (256^) <$> [3, 2, 1, 0 :: Int]
  forM_ ds $ hPutChar h
  B.hPut h s
  hFlush h

procure :: Handle -> IO ByteString
procure h = do
  ds <- unpack <$> B.hGet h 4
  when (null ds) $ ioError $ userError $ "handle closed"
  let n = sum $ zipWith (*) (ord <$> ds) $ (256^) <$> [3, 2, 1, 0 :: Int]
  when (n > 5 * 1024 * 1024) $ ioError $ userError $ "BUG! Artifact too large: " ++ show n
  r <- B.hGet h n
  when (B.null r) $ ioError $ userError $ "handle closed"
  pure r

-- | Connect to direct successors.
outConnect :: Grapevine -> [(String, SockAddr)] -> IO ()
outConnect gv succs = forM_ succs $ \(s, sock) -> do
  tmp <- socket AF_INET Stream 0
  connect tmp sock
  h <- socketToHandle tmp ReadWriteMode
  void $ forkIO $ stream gv s h

-- | If already meshed, tell direct predecesors we're back online.
inConnect :: Grapevine -> [(String, SockAddr)] -> IO ()
inConnect gv preds = (readMVar (isMeshed gv) >>=) $ flip when $
  forM_ preds $ \(_, sock) -> void $ forkIO $ do
    tmp <- socket AF_INET Stream 0
    connect tmp sock
    h <- socketToHandle tmp ReadWriteMode
    wire h $ pack $ show $ Successor $ myNetName gv
    bs <- procure h
    case readMay $ unpack bs of
      Just Predecessor -> slurp gv sock h
      _ -> ioError $ userError "WANT REPLY: 'Predecessor'"

socialize :: Grapevine -> IO ()
socialize gv = do
  ps <- readMVar $ peerage gv
  let n = M.size ps
  if n < 10 then do
    let others = filter ((/= myNetName gv) . fst) $ M.assocs ps
    outConnect gv others
    inConnect  gv others
  else kautz gv ps $ kautzRecommend n

kautz :: Grapevine -> M.Map String SockAddr -> (Int, Int) -> IO ()
kautz gv ps (m, n) = let
  sz = kautzSize m n
  lim = M.size ps
  i = M.findIndex (myNetName gv) ps
  in assert (sz >= lim) $ assert (sz <= lim * 2) $ do
    outConnect gv $ (`M.elemAt` ps) <$> kautzOutRoomy m n i lim
    inConnect  gv $ (`M.elemAt` ps) <$> kautzInRoomy  m n i lim

reportSighting :: Ord a => [Set a] -> a -> [Set a]
reportSighting seens@(a:as) h = if Set.size a == 1024
  then Set.singleton h : init seens
  else Set.insert h a : as
reportSighting [] _ = error "BUG!"

-- | Add to a stat counter.
add :: Grapevine -> Int -> String -> IO ()
add gv n s = do
  st <- takeMVar $ netStats gv
  putMVar (netStats gv) $! M.insertWith (+) s n st

-- | Incrmeent a stat counter.
inc :: Grapevine -> String -> IO ()
inc gv s = add gv 1 s

process :: Grapevine -> ByteString -> IO ()
process gv b = do
  seens <- takeMVar $ seenTables gv
  let h = SHA256.hash b
  if any (Set.member h) seens then do
    inc gv "dup"
    putMVar (seenTables gv) seens
  else do
    inc gv "in"
    putMVar (seenTables gv) $! reportSighting seens h
    status <- tryWriteChan (blobChan gv) b
    if status then do
      st <- takeMVar $ netStats gv
      let
        st1 = M.insertWith (+) "inqueue" 1 st
        n = st1 M.! "inqueue"
      putMVar (netStats gv) $!
        if n > fromMaybe 0 (M.lookup "inqueue-high-water-mark" st1) then M.insert "inqueue-high-water-mark" n st1 else st1
    else do
      inc gv "indropped"
      putStrLn "FULL BUFFER"

publish :: Grapevine -> IO ()
publish gv = do
  ps <- readMVar $ peerage gv
  ns <- readMVar $ neighbours gv
  void $ takeMVar $ isMeshed gv
  doneV <- newEmptyMVar
  let
    waitFor 0 = putMVar (isMeshed gv) True
    waitFor n = do
      takeMVar doneV
      waitFor $ n - 1
  void $ forkIO $ waitFor $ M.size ns
  -- Give every noble the Peerage, then wait for each to connect to their
  -- successors.
  forM_ ns $ \(_, h) -> void $ forkIO $ do
    wire h $ pack $ show $ Peerage False $ M.map show ps
    bs <- procure h
    when (bs /= "OK") $ ioError $ userError "EXPECT OK"
    putMVar doneV ()
  -- Only continue once all are ready.
  void $ readMVar $ isMeshed gv
  -- Listen to stats.
  forM_ (M.assocs ns) $ \(s, (_, h)) -> void $ forkIO $ do
    let
      discon e = do
        putStrLn $ "DISCONNECT: " ++ s ++ ": " ++ show (e :: SomeException)
        hClose h
    handle discon $ forever $ do
      stats <- procure h
      status <- tryWriteChan (statsChan gv) (show $ ps M.! s, stats)
      when (not status) $ do
        inc gv "statsdrop"
        putStrLn "king: STATS DROPPED"

isKing :: Grapevine -> Bool
isKing gv = isNothing $ kingHandle gv

-- | Blast messages to a handle.
-- Counterpart to `slurp`.
stream :: Grapevine -> String -> Handle -> IO ()
stream gv s h = do
  ch <- newBoundedChan 128
  ns <- takeMVar $ neighbours gv
  putMVar (neighbours gv) $ M.insert s (ch, h) ns
  wire h $ pack $ show Predecessor
  catch (forever $ readChan ch >>= wire h) $ \e -> do
    putStrLn $ "DISCONNECT: " ++ s ++ ": " ++ show (e :: SomeException)
    ns1 <- takeMVar $ neighbours gv
    putMVar (neighbours gv) $ M.delete s ns1
    hClose h

yell :: Grapevine -> ByteString -> IO ()
yell gv b = if isKing gv
  then do
    ps <- readMVar $ peerage gv
    tmp <- socket AF_INET Stream 0
    connect tmp $ snd $ M.findMin ps
    h <- socketToHandle tmp WriteMode
    wire h $ pack $ show $ Edict b
    hClose h
  else do
    inc gv "out"
    ns <- readMVar $ neighbours gv
    seens <- takeMVar $ seenTables gv
    forM_ (M.assocs ns) $ \(s, (ch, _)) -> do
      roomy <- tryWriteChan ch b
      when (not roomy) $ putStrLn $ "OUT CHANNEL FULL: " ++ s
      BChan.writeChan ch b
    putMVar (seenTables gv) $! reportSighting seens $ SHA256.hash b

hear :: Grapevine -> IO ByteString
hear gv = do
  r <- readChan $ blobChan gv
  add gv (-1) "inqueue"
  pure r

htmlNetStats :: Grapevine -> IO String
htmlNetStats gv = do
  ns <- readMVar $ neighbours gv
  ps <- readMVar $ peerage gv
  t <- readMVar $ netStats gv
  pure $ concat
    [ "out-neighbours:\n"
    , (unlines $ map show $ catMaybes $ (`M.lookup` ps) <$> M.keys ns) ++ "\n"
    , unlines $ show <$> M.assocs t
    ]

grapevineTable :: Grapevine -> IO (M.Map String Int)
grapevineTable gv = readMVar $ netStats gv
