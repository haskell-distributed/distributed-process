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
Feedback and suggestions are most welcome. Email [Duncan](mailto:duncan@well-typed.com) or [Edsko](mailto:edsko@well-typed.com) at Well-Typed, find us at #HaskellTransportLayer on
freenode, or post on the [Parallel Haskell][2] mailing list.

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

[1]: http://www.olcf.ornl.gov/center-projects/common-communication-interface/
[2]: https://groups.google.com/forum/?fromgroups#!forum/parallel-haskell
[3]: http://cloud-haskell.atlassian.net
[4]: /tutorials/2.nt_tutorial.html
[5]: /wiki/newtransports.html
[6]: /wiki/newdesign.html
[7]: /wiki/protocols.html
[8]: https://cloud-haskell.atlassian.net/issues/?filter=10002
