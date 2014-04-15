---
layout: wiki
title: Network.Transport
wiki: Overview
---

### Overview

`Network.Transport` is a Network Abstraction Layer which provides
the following high-level concepts:

* Nodes in the network are represented by `EndPoint`s. These are heavyweight stateful objects.
* Each `EndPoint` has an `EndPointAddress`.
* Connections can be established from one `EndPoint` to another using the `EndPointAddress` of the remote end.
* The `EndPointAddress` can be serialised and sent over the network, where as `EndPoint`s and connections cannot.
* Connections between `EndPoint`s are unidirectional and lightweight.
* Outgoing messages are sent via a `Connection` object that represents the sending end of the connection.
* Incoming messages for **all** of the incoming connections on an `EndPoint` are collected via a shared receive queue.
* In addition to incoming messages, `EndPoint`s are notified of other `Event`s such as new connections or broken connections.

This design was heavily influenced by the design of the [Common Communication Interface/CCI][1].
Important design goals are:

* Connections should be lightweight: it should be no problem to create thousands of connections between endpoints.
* Error handling is explicit: every function declares as part of its type which errors it can return (no exceptions are thrown)
* Error handling is "abstract": errors that originate from implementation specific problems (such as "no more sockets" in the TCP implementation) get mapped to generic errors ("insufficient resources") at the Transport level.

It is intended that `Network.Transport` can be instantiated to use
many different protocols for message passing: TCP/IP, UDP, MPI, CCI,
ZeroMQ, ssh, MVars, Unix pipes and more. Currently, we offer a TCP/IP
transport and (mostly for demonstration purposes) an in-memory
`Chan`-based transport.

### **Package status**

The TCP/IP implementation of Network.Transport should be usable, if not
completely stable yet. The design of the transport layer may also still change.
Feedback and suggestions are most welcome. Email [Duncan](mailto:duncan@well-typed.com) or [Edsko](mailto:edsko@well-typed.com) at Well-Typed, find us at #haskell-distributed on
Freenode, or post on the [Parallel Haskell][2] mailing list.

You may also submit issues on the [JIRA issue tracker][8].

### Hello World

For a flavour of what programming with `Network.Transport` looks like, here is a tiny self-contained example. 

{% highlight haskell %}
import Network.Transport
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Concurrent
import Control.Monad
import Data.String

main :: IO ()
main = do
  serverAddr <- newEmptyMVar
  clientDone <- newEmptyMVar

  Right transport <- createTransport "127.0.0.1" "10080" defaultTCPParameters
  
  -- "Server"
  forkIO $ do
    Right endpoint <- newEndPoint transport
    putMVar serverAddr (address endpoint)
   
    forever $ do
      event <- receive endpoint
      case event of
        Received _ msg -> print msg
        _ -> return () -- ignore

  -- "Client"
  forkIO $ do
    Right endpoint <- newEndPoint transport
    Right conn     <- do addr <- readMVar serverAddr 
                         connect endpoint addr ReliableOrdered defaultConnectHints
    send conn [fromString "Hello world"]
    putMVar clientDone ()

  -- Wait for the client to finish
  takeMVar clientDone
{% endhighlight %}

We create a "server" and a "client" (each represented by an `EndPoint`).
The server waits for `Event`s and whenever it receives a message it just prints
it to the console; it ignores all other messages. The client sets up a connection
to the server, sends a single message, and then signals to the main process
that it is done.

### More Information

* [Programming with Network.Transport][4] introduces `Network.Transport` from an application developer's point of view.
* [Creating New Transports][5] describes how to design new instantiations of `Network.Transport` for other messaging protocols, and describes the TCP transport in some detail as a guiding example.
* [New backend and transport design][6] has some notes about the design of the transport layer. Note however that this page is currently out of date.

### How can I help?

If you want to help with the development of `Network.Transport`, you can help in one of two ways:

1. Play with the TCP implementation. Do the tutorial [Programming with Network.Transport][4]. Write some simple applications. Make it break and report the bugs. 
2. If you have domain specific knowledge of other protocols (UDP, MPI, CCI, ZeroMQ, ssh, sctp, RUDP, enet, UDT, etc.) and you think it would be useful to have a Transport implementation for that protocol, then implement it! [Creating New Transports][5] might be a good place to start. Not only would it be great to have lots of supported protocols, but the implementation of other protocols is also a good test to see if the abstract interface that we provide in `Network.Transport` is missing anything.

Note however that the goal of `Network.Transport` is _not_ to provide a general purpose network abstraction layer, but rather it is designed to support certain kinds of applications. [New backend and transport design][6] contains some notes about this, although it is sadly out of date and describes an older version of the API.

If you are interested in helping out, please add a brief paragraph to
[Applications and Other Protocols][7] so that we can coordinate the efforts.

--------

### The TCP Transport

#### Overview

When a TCP transport is created a new server is started which listens on a
given port number on the local host. In order to support multiple connections
the transport maintains a set of channels, one per connection, represented as a
pair of a `MVar [ByteString]` and a list of pairs `(ThreadId, Socket)` of
threads that are listening on this channel. A source end then corresponds to a
hostname (the hostname used by clients to identity the local host), port
number, and channel ID; a receive end simply corresponds to a channel ID.

When `mkTransport` creates a new transport it spawns a thread that listens for
incoming connections, running `procConnections` (see below). The set of
channels (connections) associated with the transport is initialized to be
empty. 

`newConnectionWith` creates a new channel and add its to the transport channel
map (with an empty list of associated threads).

To serialize the source end we encode the triple of the local host name, port
number, and channel ID, and to deserialize we just decode the same triple
(deserialize does not need any other properties of the TCP transport).

To connect to the source end we create a new socket, connect to the server at
the IP address specified in the TCPConfig, and send the channel number over the
connection. Then to `closeSourceEnd` we simply close the socket, and to send a
bunch of byte strings we output them on the socket.

To receive from the target end we just read from the channel associated with
the target end. To `closeTargetEnd` we find kill all threads associated with
the channel and close their sockets.

When somebody connects to server (running `procConnections`), he first sends a
channel ID. `procConnections` then spawns a new thread running
`procMessages` which listens for bytestrings on the socket and output them on
the specified channel.  The ID of this new thread (and the socket it uses) are
added to the channel map of the transport.

`closeTransport` kills the server thread and all threads that were listening on
the channels associated with the transport, and closes all associated sockets.

#### Improving Latency

A series of benchmarks has shown that

* The use of `-threaded` triples the latency.

* Prepending a header to messages has a negligible effect on latency, even when
  sending very small packets. However, the way that we turn the length from an
  `Int32` to a `ByteString` _does_ have a significant impact; in particular,
  using `Data.Serialize` is very slow (and using Blaze.ByteString not much
  better).  This is fast:

{% highlight haskell %}
foreign import ccall unsafe "htonl" htonl :: CInt -> CInt

encodeLength :: Int32 -> IO ByteString
encodeLength i32 =
  BSI.create 4 $ \p ->
    pokeByteOff p 0 (htonl (fromIntegral i32))
{% endhighlight %}

* We do not need to use `blaze-builder` or related; 
  `Network.Socket.Bytestring.sendMany` uses vectored I/O. On the client side
  doing a single `recv` to try and read the message header and message, rather
  one to read the header and one to read the payload improves latency, but only
  by a tiny amount. 

* Indirection through an `MVar` or a `Chan` does not have an observable effect
  on latency.  

* When two nodes _A_ and _B_ communicate, latency is worse when they
  communicate over two pairs of sockets (used unidirectionally) rather than one
  pair (used bidirectionally) by about 20%. This is not improved by using
  `TCP_NODELAY`, and might be because [acknowledgements cannot piggyback with
  payload][9] this way. It might thus be worthwhile to try and reuse TCP
  connections (or use UDP).

----

### Adding Support for Multicast to the Transport API

Here we describe various design options for adding support for multicast
to the Transport API.

#### Creating a new multicast group 

We can either have this as part of the transport

{% highlight haskell %}
  data Transport = Transport {
      ...
    , newMulticastGroup :: IO (Either Error MulticastGroup)
    }

  data MulticastGroup = MulticastGroup {
      ...
    , multicastAddress     :: MulticastAddress
    , deleteMulticastGroup :: IO ()
    }
{% endhighlight %}

or as part of an endpoint:

{% highlight haskell %}
  data Transport = Transport {
      newEndPoint :: IO (Either Error EndPoint)
    }

  data EndPoint = EndPoint {
      ...
    , newMulticastGroup :: IO (Either Error MulticastGroup)
    }
{% endhighlight %}

It should probably be part of the `Transport`, as there is no real connection
between an endpoint and the creation of the multigroup (however, see section
"Sending messages to a multicast group").

#### Subscribing to a multicast group

This should be part of an endpoint; subscribing basically means that the
endpoint wants to receive events when multicast messages are sent.

We could reify a subscription:

{% highlight haskell %}
  data EndPoint = EndPoint {
      ...
    , multicastSubscribe :: MulticastAddress -> IO MulticastSubscription
    }

  data MulticastSubscription = MulticastSubscription {
      ... 
      , multicastSubscriptionClose :: IO ()
    }
{% endhighlight %}

but this suggests that one might have multiple subscriptions to the same group
which can be distinguished, which is misleading. Probably better to have:

{% highlight haskell %}
  data EndPoint = EndPoint {
      multicastSubscribe   :: MulticastAddress -> IO ()
    , multicastUnsubscribe :: MulticastAddress -> IO ()
    }
{% endhighlight %}

#### Sending messages to a multicast group

An important feature of the Transport API is that we are clear about which
operations are *lightweight* and which are not. For instance, creating new
endpoints is not lightweight, but opening new connections to endpoints is (as
light-weight as possible). 

Clearly the creation of a new multicast group is a heavyweight operation. It is
less evident however if we can support multiple lightweight "connections" to the
same multicast group, and if so, whether it is useful.

If we decide that multiple lightweight connections to the multigroup is useful,
one option might be

{% highlight haskell %}
  data EndPoint = EndPoint {
      ...
    , connect :: Address -> Reliability -> IO (Either Error Connection)
    , multicastConnect :: MulticastAddress -> IO (Either Error Connection) 
  } 

  data Connection = Connection {
      connectionId :: ConnectionId 
    , send         :: [ByteString] -> IO ()
    , close        :: IO ()
    , maxMsgSize   :: Maybe Int 
    }

  data Event = 
      Receive ConnectionId [ByteString]
    | ConnectionClosed ConnectionId
    | ConnectionOpened ConnectionId ConnectionType Reliability Address 
{% endhighlight %}

The advantage of this approach is it's consistency with the rest of the
interface. The problem is that with multicast we cannot reliably send any
control messages, so we cannot make sure that the subscribers of the multicast
group will receive ConnectionOpened events when an endpoint creates a new
connection.  Since we don't support these "connectionless connections" anywhere
else in the API this seems inconsistent with the rest of the design (this
implies that an "unreliable" Transport over UDP still needs to have reliable
control messages).  (On the other hand, if we were going to support reliable
multicast protocols, then that would fit this design).

If we don't want to support multiple lightweight connections to a multicast
group then a better design would be

{% highlight haskell %}
  data EndPoint = EndPoint {
    , connect       :: Address -> Reliability -> IO (Either Error Connection)
    , multicastSend :: MulticastAddress -> [ByteString] -> IO ()
  } 

  data Event = 
      ...
    | MulticastReceive Address [ByteString]
{% endhighlight %}

or alternatively

{% highlight haskell %}
  data EndPoint = EndPoint {
      ...
    , resolveMulticastGroup :: MulticastAddress -> IO (Either Error MulticastGroup) 
    } 

  data MulticastGroup = MulticastGroup {
    , ...
    , send :: [ByteString] -> IO ()
    }
{% endhighlight %}

If we do this however we need to make sure that newGroup is part an `EndPoint`,
not the `Transport`, otherwise `send` will not know the source of the message.
The version with `resolveMulticastGroup` has the additional benefit that in
"real" implementations we will probably need to allocate some resources before
we can send to the multicast group, and need to deallocate these resources at
some point too. 

### The current solution

The above considerations lead to the following tentative proposal:

{% highlight haskell %}
  data Transport = Transport {
      newEndPoint :: IO (Either Error EndPoint)
    }

  data EndPoint = EndPoint {
      receive :: IO Event
    , address :: Address 
    , connect :: Address -> Reliability -> IO (Either Error Connection)
    , newMulticastGroup     :: IO (Either Error MulticastGroup)
    , resolveMulticastGroup :: MulticastAddress -> IO (Either Error MulticastGroup)
    } 

  data Connection = Connection {
      send  :: [ByteString] -> IO ()
    , close :: IO ()
    }

  data Event = 
      Receive ConnectionId [ByteString]
    | ConnectionClosed ConnectionId
    | ConnectionOpened ConnectionId Reliability Address 
    | MulticastReceive MulticastAddress [ByteString]

  data MulticastGroup = MulticastGroup {
      multicastAddress     :: MulticastAddress
    , deleteMulticastGroup :: IO ()
    , maxMsgSize           :: Maybe Int 
    , multicastSend        :: [ByteString] -> IO ()
    , multicastSubscribe   :: IO ()
    , multicastUnsubscribe :: IO ()
    , multicastClose       :: IO ()
    }
{% endhighlight %}

where `multicastClose` indicates to the runtime that this endpoint no longer
wishes to send to this multicast group, and we can therefore deallocate the
resources we needed to send to the group (these resources can be allocated on
`resolveMulticastGroup` or on the first `multicastSend`; the advantage of the
latter is that is somebody resolves a group only to subscribe to it, not to
send to it, we don't allocate any unneeded resources).

[1]: http://www.olcf.ornl.gov/center-projects/common-communication-interface/
[2]: https://groups.google.com/forum/?fromgroups#!forum/parallel-haskell
[3]: http://cloud-haskell.atlassian.net
[4]: /tutorials/2.nt_tutorial.html
[5]: /wiki/newtransports.html
[6]: /wiki/newdesign.html
[7]: /wiki/protocols.html
[8]: https://cloud-haskell.atlassian.net/issues/?filter=10002
[9]: http://lists.freebsd.org/pipermail/freebsd-hackers/2009-March/028006.html "2 uni-directional TCP connection good?"
