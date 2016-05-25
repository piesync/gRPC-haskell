{-# LANGUAGE OverloadedStrings #-}

module LowLevelTests where

import           Control.Concurrent.Async
import           Data.ByteString                (ByteString)
import qualified Data.Map                       as M
import           Foreign.Marshal.Alloc
import           Foreign.Ptr
import           Foreign.Storable
import           Network.GRPC.LowLevel
import           Network.GRPC.Unsafe
import           Network.GRPC.Unsafe.ByteBuffer
import           Network.GRPC.Unsafe.Constants
import           Network.GRPC.Unsafe.Metadata
import           Network.GRPC.Unsafe.Op
import           Network.GRPC.Unsafe.Time
import           Test.Tasty
import           Test.Tasty.HUnit               as HU (testCase, (@?=))

lowLevelTests :: TestTree
lowLevelTests = testGroup "Unit tests of low-level Haskell library"
  [  testGRPCBracket
   , testCompletionQueueCreateDestroy
   , testServerCreateDestroy
   , testClientCreateDestroy
   , testWithServerCall
   , testWithClientCall
   , testPayloadLowLevel
   , testClientRequestNoServer
   , testServerAwaitNoClient
   , testPayloadLowLevelUnregistered
   , testPayload
   ]
  ]

dummyMeta :: M.Map ByteString ByteString
dummyMeta = M.fromList [("foo","bar")]

testGRPCBracket :: TestTree
testGRPCBracket = testCase "Start/stop GRPC" $
  withGRPC $ const $ return ()

testCompletionQueueCreateDestroy :: TestTree
testCompletionQueueCreateDestroy =
  testCase "Create/destroy completion queue" $ withGRPC $ \grpc ->
    withCompletionQueue grpc $ const (return ())

testServerCreateDestroy :: TestTree
testServerCreateDestroy =
  testCase "Server - start/stop" $
  withGRPC $ \grpc -> withServer grpc (ServerConfig "localhost" 50051 [])
                                 (const $ return ())

testClientCreateDestroy :: TestTree
testClientCreateDestroy =
  testCase "Client - start/stop" $
  withGRPC $ \grpc -> withClient grpc (ClientConfig "localhost" 50051)
                                 (const $ return ())

testPayloadLowLevelServer :: GRPC -> IO ()
testPayloadLowLevelServer grpc = do
  let conf = (ServerConfig "localhost" 50051 [("/foo", "localhost", Normal)])
  withServer grpc conf $ \server -> do
    let method = head (registeredMethods server)
    result <- serverHandleNormalRegisteredCall server method 11 M.empty $
                \reqBody reqMeta ->
                  return ("reply test", dummyMeta, dummyMeta,
                          StatusDetails "details string")
    case result of
      Left err -> error $ show err
      Right _ -> return ()

testPayloadLowLevelClient :: GRPC -> IO ()
testPayloadLowLevelClient grpc =
  withClient grpc (ClientConfig "localhost" 50051) $ \client -> do
    method <- clientRegisterMethod client "/foo" "localhost" Normal
    putStrLn "registered method on client."
    reqResult <- clientRegisteredRequest client method 10 "Hello!" M.empty
    case reqResult of
      Left x -> error $ "Client got error: " ++ show x
      Right (NormalRequestResult respBody initMeta trailingMeta respCode details) -> do
        details @?= "details string"
        respBody @?= "reply test"
        respCode @?= GrpcStatusOk

testPayloadLowLevelClientUnregistered :: GRPC -> IO ()
testPayloadLowLevelClientUnregistered grpc = do
  withClient grpc (ClientConfig "localhost" 50051) $ \client -> do
    reqResult <- clientRequest client "/foo" "localhost" 10 "Hello!" M.empty
    case reqResult of
      Left x -> error $ "Client got error: " ++ show x
      Right (NormalRequestResult
              respBody initMeta trailingMeta respCode details) -> do
        respBody @?= "reply test"
        respCode @?= GrpcStatusOk
        details @?= "details string"

testPayloadLowLevelServerUnregistered :: GRPC -> IO ()
testPayloadLowLevelServerUnregistered grpc = do
  withServer grpc (ServerConfig "localhost" 50051 []) $ \server -> do
    result <- serverHandleNormalCall server 11 M.empty $
                \reqBody reqMeta -> return ("reply test", M.empty,
                                            StatusDetails "details string")
    case result of
      Left x -> error $ show x
      Right _ -> return ()

testClientRequestNoServer :: TestTree
testClientRequestNoServer =
  testCase "Client - request timeout when server DNE" $
  withGRPC $ \grpc -> do
    withClient grpc (ClientConfig "localhost" 50051) $ \client -> do
      method <- clientRegisterMethod client "/foo" "localhost" Normal
      reqResult <- clientRegisteredRequest client method 1 "Hello" M.empty
      reqResult @?= (Left GRPCIOTimeout)

testServerAwaitNoClient :: TestTree
testServerAwaitNoClient =
  testCase "Server - registered call handler timeout" $
  withGRPC $ \grpc -> do
    let conf = (ServerConfig "localhost" 50051 [("/foo", "localhost", Normal)])
    withServer grpc conf $ \server -> do
      let method = head (registeredMethods server)
      result <- serverHandleNormalRegisteredCall server method 1 M.empty $
                  \_ _ -> return ("", M.empty, M.empty, StatusDetails "details")
      result @?= Left GRPCIOTimeout

testServerUnregisteredAwaitNoClient :: TestTree
testServerUnregisteredAwaitNoClient =
  testCase "Server - unregistered call handler timeout" $
    withGRPC $ \grpc -> do
      let conf = ServerConfig "localhost" 50051 []
      withServer grpc conf $ \server -> do
        result <- serverHandleNormalCall server 10 M.empty $
                    \_ _ -> return ("", M.empty, StatusDetails "")
        case result of
          Left err -> error $ show err
          Right _ -> return ()

testPayloadLowLevel :: TestTree
testPayloadLowLevel =
  testCase "Client/Server - low-level (registered) request/response" $
    withGRPC $ \grpc -> do
      withAsync (testPayloadLowLevelServer grpc) $ \a1 -> do
        withAsync (testPayloadLowLevelClient grpc) $ \a2 -> do
          wait a1
          wait a2

testPayloadLowLevelUnregistered :: TestTree
testPayloadLowLevelUnregistered =
  testCase "Client/Server - low-level unregistered request/response" $ do
    withGRPC $ \grpc -> do
      withAsync (testPayloadLowLevelServerUnregistered grpc) $ \a1 ->
        withAsync (testPayloadLowLevelClientUnregistered grpc) $ \a2 -> do
          wait a1
          wait a2

testWithServerCall :: TestTree
testWithServerCall =
  testCase "Server - Create/destroy call" $
    withGRPC $ \grpc -> do
      let conf = ServerConfig "localhost" 50051 []
      withServer grpc conf $ \server -> do
        result <- withServerCall server 1 $ const $ return $ Right ()
        result @?= Left GRPCIOTimeout

testWithClientCall :: TestTree
testWithClientCall =
  testCase "Client - Create/destroy call" $
    withGRPC $ \grpc -> do
      let conf = ClientConfig "localhost" 50051
      withClient grpc conf $ \client -> do
        result <- withClientCall client "foo" "localhost" 10 $
                    const $ return $ Right ()
        case result of
          Left err -> error $ show err
          Right _ -> return ()

assertCqEventComplete :: Event -> IO ()
assertCqEventComplete e = do
  eventCompletionType e HU.@?= OpComplete
  eventSuccess e HU.@?= True

testPayloadClient :: IO ()
testPayloadClient = do
  client <- grpcInsecureChannelCreate "localhost:50051" nullPtr reserved
  cq <- grpcCompletionQueueCreate reserved
  withMetadataArrayPtr $ \initialMetadataRecv -> do
    withMetadataArrayPtr $ \trailingMetadataRecv -> do
      withByteBufferPtr $ \clientRecvBB -> do
        deadline <- secondsToDeadline 5
        pluckDeadline <- secondsToDeadline 10
        clientCall <- grpcChannelCreateCall
                        client (Call nullPtr) propagateDefaults cq
                        "/foo" "localhost" deadline reserved
        --send request
        withOpArray 6 $ \ops -> do
          opSendInitialMetadataEmpty ops 0
          withByteStringAsByteBuffer "hello world" $ \requestPayload -> do
            opSendMessage ops 1 requestPayload
            opSendCloseClient ops 2
            opRecvInitialMetadata ops 3 initialMetadataRecv
            opRecvMessage ops 4 clientRecvBB
            statusCodePtr <- createStatusCodePtr
            let cstringCapacity = 32
            cStringPtr <- malloc
            cstring <- mallocBytes cstringCapacity
            poke cStringPtr cstring
            opRecvStatusClient ops 5 trailingMetadataRecv statusCodePtr
                               cStringPtr
                               cstringCapacity
            --send client request
            requestError <- grpcCallStartBatch clientCall ops 6 (tag 1) reserved
            clientRequestCqEvent <- grpcCompletionQueuePluck
                                      cq (tag 1) pluckDeadline reserved
            assertCqEventComplete clientRequestCqEvent
            requestError HU.@?= CallOk
            free cstring
            free cStringPtr
            destroyStatusCodePtr statusCodePtr
        --verify response received
        responseRecv <- peek clientRecvBB
        responseRecvBS <- copyByteBufferToByteString responseRecv
        responseRecvBS HU.@?= "hello you"
        grpcCompletionQueueShutdown cq
        grpcCallDestroy clientCall
        --TODO: the grpc test drains the cq here
        grpcCompletionQueueDestroy cq
        grpcChannelDestroy client

testPayloadServer :: IO ()
testPayloadServer = do
  server <- grpcServerCreate nullPtr reserved
  cq <- grpcCompletionQueueCreate reserved
  grpcServerRegisterCompletionQueue server cq reserved
  _ <- grpcServerAddInsecureHttp2Port server "localhost:50051"
  grpcServerStart server
  serverCallPtr <- malloc
  withMetadataArrayPtr $ \requestMetadataRecv -> do
    withByteBufferPtr $ \recvBufferPtr -> do
      callDetails <- createCallDetails
      requestMetadataRecv' <- peek requestMetadataRecv
      recvRequestError <- grpcServerRequestCall
                            server serverCallPtr callDetails
                            requestMetadataRecv' cq cq (tag 101)
      pluckDeadline' <- secondsToDeadline 10
      requestCallCqEvent <- grpcCompletionQueuePluck cq (tag 101)
                                                     pluckDeadline'
                                                     reserved
      assertCqEventComplete requestCallCqEvent
      recvRequestError HU.@?= CallOk
      destroyCallDetails callDetails
      --receive request
      withOpArray 2 $ \recvOps -> do
        opSendInitialMetadataEmpty recvOps 0
        opRecvMessage recvOps 1 recvBufferPtr
        serverCall <- peek serverCallPtr
        recvBatchError <- grpcCallStartBatch serverCall recvOps 2
                                             (tag 102) reserved
        recvBatchError HU.@?= CallOk
        pluckDeadline'' <- secondsToDeadline 10
        recvCqEvent <- grpcCompletionQueuePluck cq (tag 102)
                                                pluckDeadline''
                                                reserved
        assertCqEventComplete recvCqEvent
      --send response
      withOpArray 3 $ \respOps -> do
        withByteStringAsByteBuffer "hello you" $ \respbb -> do
          cancelledPtr <- malloc
          opRecvCloseServer respOps 0 cancelledPtr
          opSendMessage respOps 1 respbb
          B.useAsCString "ok" $ \detailsStr ->
            opSendStatusServer respOps 2 0 (MetadataKeyValPtr nullPtr)
                               GrpcStatusOk detailsStr
          serverCall <- peek serverCallPtr
          respBatchError <- grpcCallStartBatch serverCall respOps 3
                                               (tag 103) reserved
          respBatchError HU.@?= CallOk
          pluckDeadline''' <- secondsToDeadline 10
          respCqEvent <- grpcCompletionQueuePluck cq (tag 103)
                                                  pluckDeadline'''
                                                  reserved
          assertCqEventComplete respCqEvent
      --verify data was received
      serverRecv <- peek recvBufferPtr
      serverRecvBS <- copyByteBufferToByteString serverRecv
      serverRecvBS HU.@?= "hello world"
      --shut down
      grpcServerShutdownAndNotify server cq (tag 0)
      pluckDeadline'''' <- secondsToDeadline 10
      shutdownEvent <- grpcCompletionQueuePluck cq (tag 0) pluckDeadline''''
                                                reserved
      assertCqEventComplete shutdownEvent
      grpcServerCancelAllCalls server
      grpcServerDestroy server
      grpcCompletionQueueShutdown cq
      grpcCompletionQueueDestroy cq
      free serverCallPtr

-- | Straightforward translation of the gRPC core test end2end/tests/payload.c
-- This is intended to test the low-level C bindings, so we use only a few
-- minimal abstractions on top of it.
testPayload :: TestTree
testPayload = testCase "Client/Server - End-to-end request/response" $ do
  grpcInit
  withAsync testPayloadServer $ \a1 -> do
    withAsync testPayloadClient $ \a2 -> do
      wait a1
      wait a2
  grpcShutdown
  putStrLn "Done."
