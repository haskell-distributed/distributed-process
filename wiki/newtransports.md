---
layout: wiki
title: Building new Transports
wiki: Guide
---

## Guide

On this page we describe the TCP Transport as an example for developers who wish to write their own instantiations of the Transport layer. The purpose of any such instantiation is to provide a function

{% highlight haskell %}
createTransport :: <transport specific arguments> -> IO (Either <transport specific error> Transport)
{% endhighlight %}

For instance, the TCP transport offers

{% highlight haskell %}
createTransport :: N.HostName -> N.ServiceName -> IO (Either IOException Transport)
{% endhighlight %}

This could be the only function that `Network.Transport.TCP` exports (the only reason it exports more is to provide an API for unit tests for the TCP transport, some of which work at a lower level). Your implementation will now be guided by the `Network.Transport` API. In particular, you will need to implement `newEndPoint`, which in turn will require you to implement `receive`, `connect`, etc. 

#### Mapping Network.Transport concepts to TCP

The following picture is a schematic overview of how the Network.Transport concepts map down to their TCP counterparts. 

----
![The TCP transport](/img/NetworkTCP.png)

----

* The blue boxes represent `Transport` instances. At the top we have two Transport instances on the same TCP node 198.51.100.1. These could be as part of the same Haskell process or, perhaps more typically, in separate processes. Different Transport instances on the same host must get a different port number.
* The orange boxes represent `EndPoint`s. A Transport can have multiple EndPoints (or none). EndPointAddresses in the TCP transport are triplets `TCP host:TCP port:endpoint ID`. 
* The heavyset lines represent (heavyweight, bidirectional) TCP connections; the squiggly lines represent Transport level (lightweight, unidirectional) connections. The TCP transport guarantees that at most a single TCP connection will be set up between any pair of endpoints; all lightweight connections get multiplexed over this single connection.
* All squiggly lines end up in a single fat dot in the middle of the endpoint. This represents a `Chan` on which all endpoint `Event`s are posted. 

## Implementation

We briefly discuss the implementation of the most important functions in the Transport API.

#### Setup (`createTransport`)

When a TCP transport is created at host 192.51.100.1, port 1080, `createTransport` sets up a socket, binds it to 192.51.100.1:1080, and then spawns a thread to listen for incoming requests. This thread will handle the connection requests for all endpoints on this TCP node: individual endpoints do _not_ set up their own listening sockets.

This is the only set up that `Network.Transport.TCP.createTransport` needs to do. 

#### Creating new endpoints (`newEndPoint`)

In the TCP transport the set up of new endpoints is straightforward. We only need to create a new `Chan` on which we will output all the events and allocate a new ID for the endpoint. Now `receive` is just `readChan` and `address` is the triplet `host:port:ID`

#### New connections (`connect`)

Consider the situation shown in the diagram above, and suppose that endpoint 198.51.100.1:1081:0 (lets call it _A_) wants to connect to 198.51.100.2:1080:1 (_B_). Since there is no TCP connection between these two endpoints yet we must set one up.

* _A_ creates a socket and connects to 198.51.100.2:1080. The transport thread at 198.51.100.2 accepts the connection.
* _A_ now sends two messages across the socket: first, the ID of the remote endpoint it wants to connect to (1) and then it own full address (192.51.100.1:1081:0). The first message is necessary because the remote transport is responsible for handling the connection requests for all its endpoints. The second message is necessary to ensure that when _B_ subsequently attempts to `connect` to _A_ we know that a TCP connection to _A_ is already available.
* _B_ will respond with `ConnectionRequestAccepted` and spawn a thread to listen for incoming messages on the newly created TCP connection. 

At this point there is a TCP connection between _A_ and _B_ but not yet a Network.Transport connection; at this point, however, the procedure is the same for all connection requests from _A_ to _B_ (as well as as from _B_ to _A_):

* _A_ sends a `RequestConnectionId` message to _B_ across the existing TCP connection.
* _B_ creates a new connection ID and sends it back to _A_. At this point _B_ will output a `ConnectionOpened` on _B_'s endpoint.

> A complication arises when _A_ and _B_ simultaneously attempt to connect each other and no TCP connection has yet been set up. In this case _two_ TCP connections will temporarily be created; _B_ will accept the connection request from _A_, keeping the first TCP connection, but _A_ will reply with `ConnectionRequestCrossed`, denying the connection request from _B_, and then close the socket. 

Note that connection IDs are _locally_ unique. When _A_ and _B_ both connect to _C_, then _C_ will receive two `ConnectionOpened` events with IDs (say) 1024 and 1025. However, when _A_ connects to _B_ and _C_, then it is entirely possible that the connection ID that _A_ receives from both _B_ and _C_ is identical. Connection IDs for outgoing connections are however not visible to application code.

#### Sending messages (`send`)

To send a message from _A_ to _B_ the payload is given a Transport header consisting of the message length and the connection ID. When _B_ receives the message it posts a `Received` event.

#### Closing a connection

To close a connection, _A_ just sends a `CloseConnection` request to _B_, and _B_ will post a `ConnectionClosed` event.

When there are no more Transport connections between two endpoints the TCP connection between them is torn down.

> Actually, it's not quite that simple, because _A_ and _B_ need to agree that the TCP connection is no longer required. _A_ might think that the connection can be torn down, but there might be a `RequestConnectionId` message from _B_ to _A_ in transit in the network. _A_ and _B_ both do reference counting on the TCP connection. When _A_'s reference count for its connection to _B_ reaches zero it will send a `CloseSocket` request to _B_. When _B_ receives it, and its refcount for its connection to _A_ is also zero, it will close its socket and reply with a reciprocal `CloseSocket` to _A_. If however _B_ had already sent a `RequestConnectionId` to _A_ it will simply ignore the `CloseSocket` request, and when _A_ receives the `RequestConnectionId` it simply forgets it ever sent the `CloseSocket` request.

#### Transport instances for connectionless protocols

In the TCP transport `createTransport` needs to do some setup, `newEndPoint` barely needs to do any at all, and `connect` needs to set up a TCP connection when none yet exists to the destination endpoint. In Transport instances for connectionless protocols this balance of work will be different. For instance, for a UDP transport `createTransport` may barely need to do any setup, `newEndPoint` may set up a UDP socket for the endpoint, and `connect` may only have to setup some internal datastructures and send a UDP message.

#### Error handling

Network.Transport API functions should not throw any exceptions, but declare explicitly in their types what errors can be returned. This means that we are very explicit about which errors can occur, and moreover map Transport-specific errors ("socket unavailable") to generic Transport errors ("insufficient resources"). A typical example is `connect` with type:

{% highlight haskell %}
connect :: EndPoint         -- ^ Local endpoint
        -> EndPointAddress  -- ^ Remote endpoint
        -> Reliability      -- ^ Desired reliability of the connection
        -> IO (Either (TransportError ConnectErrorCode) Connection)
{% endhighlight %}

`TransportError` is defined as

{% highlight haskell %}
data TransportError error = TransportError error String
  deriving Typeable
{% endhighlight %}

and has `Show` and `Exception` instances so that application code has the option of `throw`ing returned errors. Here is a typical example of error handling in the TCP transport; it is an internal function that does the initial part of the TCP connection setup: create a new socket, and the remote endpoint ID we're interested in and our own address, and then wait for and return the response:

{% highlight haskell %}
socketToEndPoint :: EndPointAddress -- ^ Our address 
                 -> EndPointAddress -- ^ Their address
                 -> IO (Either (TransportError ConnectErrorCode) (N.Socket, ConnectionRequestResponse)) 
socketToEndPoint (EndPointAddress ourAddress) theirAddress = try $ do 
    (host, port, theirEndPointId) <- case decodeEndPointAddress theirAddress of 
      Nothing  -> throw (failed . userError $ "Could not parse")
      Just dec -> return dec
    addr:_ <- mapExceptionIO invalidAddress $ N.getAddrInfo Nothing (Just host) (Just port)
    bracketOnError (createSocket addr) N.sClose $ \sock -> do
      mapExceptionIO failed $ N.setSocketOption sock N.ReuseAddr 1
      mapExceptionIO invalidAddress $ N.connect sock (N.addrAddress addr) 
      response <- mapExceptionIO failed $ do
        sendMany sock (encodeInt32 theirEndPointId : prependLength [ourAddress]) 
        recvInt32 sock
      case tryToEnum response of
        Nothing -> throw (failed . userError $ "Unexpected response")
        Just r  -> return (sock, r)
  where
    createSocket :: N.AddrInfo -> IO N.Socket
    createSocket addr = mapExceptionIO insufficientResources $
      N.socket (N.addrFamily addr) N.Stream N.defaultProtocol

    invalidAddress, insufficientResources, failed :: IOException -> TransportError ConnectErrorCode
    invalidAddress        = TransportError ConnectNotFound . show 
    insufficientResources = TransportError ConnectInsufficientResources . show 
    failed                = TransportError ConnectFailed . show
{% endhighlight %}

Note how exceptions get mapped to `TransportErrors` using `mapExceptionID`, which is defined in `Network.Transport.Internal` as

{% highlight haskell %}
    mapExceptionIO :: (Exception e1, Exception e2) => (e1 -> e2) -> IO a -> IO a
    mapExceptionIO f p = catch p (throw . f)
{% endhighlight %}

Moreover, the original exception is used as the `String` part of the `TransportError`. This means that application developers get transport-specific feedback, which is useful for debugging, not cannot take use this transport-specific information in their _code_, which would couple applications to tightly with one specific transport implementation.
