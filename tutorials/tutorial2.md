---
layout: tutorial2
categories: tutorial
title: Programming with Network.Transport
---

### Introduction

This is a tutorial introduction to `Network.Transport`. To follow along,
you should probably already be familiar with `Control.Concurrent`; in
particular, the use of `fork` and `MVar`s. The code for the tutorial can
be downloaded as [tutorial-server.hs](/static/tutorial/tutorial-server.hs)
and [tutorial-client.hs](/static/tutorial/tutorial-client.hs).

-------

### The Network Transport API

Network.Transport is a network abstraction layer which offers the following concepts:

* Nodes in the network are represented by `EndPoint`s. These are heavyweight stateful objects.
* Each `EndPoint` has an `EndPointAddress`.
* Connections can be established from one `EndPoint` to another using the `EndPointAddress` of the remote end.
* The `EndPointAddress` can be serialised and sent over the network, where as `EndPoint`s and connections cannot.
* Connections between `EndPoint`s are unidirectional and lightweight.
* Outgoing messages are sent via a `Connection` object that represents the sending end of the connection.
* Incoming messages for **all** of the incoming connections on an `EndPoint` are collected via a shared receive queue.
* In addition to incoming messages, `EndPoint`s are notified of other `Event`s such as new connections or broken connections.

In this tutorial we will create a simple "echo" server. Whenever a client
opens a new connection to the server, the server in turns opens a connection
back to the client. All messages that the client sends to the server will
echoed by the server back to the client.

Here is what it will look like. We can start the server on one host:

{% highlight bash %}
# ./tutorial-server 192.168.1.108 8080
Echo server started at "192.168.1.108:8080:0"
{% endhighlight %}

then start the client on another. The client opens a connection to the server,
sends "Hello world", and prints all the `Events` it receives:

{% highlight bash %}
# ./tutorial-client 192.168.1.109 8080 192.168.1.108:8080:0
ConnectionOpened 1024 ReliableOrdered "192.168.1.108:8080:0"
Received 1024 ["Hello world"]
ConnectionClosed 1024
{% endhighlight %}

The client receives three `Event`s:

1. The server (with address "192.168.1.108:8080:0") opened a connection back to the client. The ID of this connection is 1024, and the connection is reliable and ordered (see below).
2. Received a message on connection 1024: that is, on the connection the server just opened. This is the server echoing the message we sent.
3. Connection 1024 was closed. 

Note that the server prints its address ("192.168.1.108:8080:0") to the
console when started and this must be passed explicitly as an argument to
the client. Peer discovery and related issues are outside the scope of
`Network.Transport`.

### Writing the client

We will start with the client 
([tutorial-client.hs](https://github.com/haskell-distributed/distributed-process/blob/master/doc/tutorial/tutorial-client.hs)),
because it is simpler. We first need a bunch of imports:

{% highlight haskell %}
import Network.Transport
import Network.Transport.TCP (createTransport)
import System.Environment
import Data.ByteString.Char8
import Control.Monad
{% endhighlight %}

The client will consist of a single main function.

{% highlight haskell %}
main :: IO ()
main = do
{% endhighlight %}

When we start the client we expect three command line arguments.
Since the client will itself be a network endpoint, we need to know the IP
address and port number to use for the client. Moreover, we need to know the
endpoint address of the server (the server will print this address to the
console when it is started):

{% highlight haskell %}
[host, port, serverAddr] <- getArgs
{% endhighlight %}

Next we need to initialize the Network.Transport layer using `createTransport`
from `Network.Transport.TCP` (in this tutorial we will use the TCP instance of
`Network.Transport`). The type of `createTransport` is:

{% highlight haskell %}
createTransport :: N.HostName -> N.ServiceName -> IO (Either IOException Transport)
{% endhighlight %}

(where `N` is an alias for `Network.Socket`). For the sake of this tutorial we
are going to ignore all error handling, so we are going to assume it will return
a `Right` transport:

{% highlight haskell %}
Right transport <- createTransport host port 
{% endhighlight %}

Next we need to create an EndPoint for the client. Again, we are going
to ignore errors:

{% highlight haskell %}
Right endpoint  <- newEndPoint transport
{% endhighlight %}

Now that we have an endpoint we can connect to the server, after we convert
the `String` we got from `getArgs` to an `EndPointAddress`:

{% highlight haskell %}
let addr = EndPointAddress (pack serverAddr)
Right conn <- connect endpoint addr ReliableOrdered defaultConnectHints
{% endhighlight %}

`ReliableOrdered` means that the connection will be reliable (no messages will be
lost) and ordered (messages will arrive in order). For the case of the TCP transport
this makes no difference (_all_ connections are reliable and ordered), but this may
not be true for other transports. 

Sending on our new connection is very easy:

{% highlight haskell %}
send conn [pack "Hello world"]
{% endhighlight %}

(`send` takes as argument an array of `ByteString`s).
Finally, we can close the connection:

{% highlight haskell %}
close conn
{% endhighlight %}

Function `receive` can be used to get the next event from an endpoint. To print the
first three events, we can do

{% highlight haskell %}
replicateM_ 3 $ receive endpoint >>= print
{% endhighlight %}

Since we're not expecting more than 3 events, we can now close the transport.

{% highlight haskell %}
closeTransport transport
{% endhighlight %}

That's it! Here is the entire client again:

{% highlight haskell %}
main :: IO ()
main = do
  [host, port, serverAddr] <- getArgs
  Right transport <- createTransport host port 
  Right endpoint  <- newEndPoint transport

  let addr = EndPointAddress (fromString serverAddr)
  Right conn <- connect endpoint addr ReliableOrdered defaultConnectHints
  send conn [fromString "Hello world"]
  close conn

  replicateM_ 3 $ receive endpoint >>= print 

  closeTransport transport
{% endhighlight %}

### Writing the server

The server ([tutorial-server.hs](https://github.com/haskell-distributed/distributed-process/blob/master/doc/tutorial/tutorial-server.hs))
is slightly more complicated, but only slightly. As with the client, we
start with a bunch of imports:

{% highlight haskell %}
import Network.Transport
import Network.Transport.TCP (createTransport)
import Control.Concurrent
import Data.Map
import Control.Exception
import System.Environment
{% endhighlight %}

We will write the main function first:

{% highlight haskell %}
main :: IO ()
main = do
  [host, port]    <- getArgs
  serverDone      <- newEmptyMVar
  Right transport <- createTransport host port 
  Right endpoint  <- newEndPoint transport
  forkIO $ echoServer endpoint serverDone 
  putStrLn $ "Echo server started at " ++ show (address endpoint)
  readMVar serverDone `onCtrlC` closeTransport transport
{% endhighlight %}

This is very similar to the `main` function for the client. We get the
hostname and port number that the server should use and create a transport
and an endpoint. Then we fork a thread to do the real work. We will write
`echoServer` next; for now, suffices to note that `echoServer` will signal
on the MVar `serverDone` when it completes, so that the main thread knows
when to exit. Don't worry about `onCtrlC` for now; it does what the
name suggests.

The goal of `echoServer` is simple: whenever somebody opens a connection to us,
open a connection to them; whenever somebody sends us a message, echo that message;
and whenever somebody closes their connection to us, we are going to close
our connection to them. 

`Event` is defined in `Network.Transport` as

{% highlight haskell %}
data Event = 
    Received ConnectionId [ByteString]
  | ConnectionClosed ConnectionId
  | ConnectionOpened ConnectionId Reliability EndPointAddress 
  | EndPointClosed
  ...
{% endhighlight %}

(there are few other events, which we are going to ignore). `ConnectionId`s help us
distinguish messages sent on one connection from messages sent on another. In
`echoServer` we are going to maintain a mapping from those `ConnectionId`s to the
connections that we will use to reply:

* Whenever somebody opens a connection, we open a connection in the other direction and add it to the map.
* Whenever we receive a message, we lookup the corresponding return connection and echo the message back.
* Whenever somebody closes the connection, we lookup and close the corresponding return connection.

Finally, when we receive the `EndPointClosed` message we signal to the main
thread that we are doing and terminate. We will receive this message when the
main thread calls `closeTransport` (that is, when the user presses Control-C). 

{% highlight haskell %}
echoServer :: EndPoint -> MVar () -> IO ()
echoServer endpoint serverDone = go empty
  where
    go :: Map ConnectionId (MVar Connection) -> IO () 
    go cs = do
      event <- receive endpoint
      case event of
        ConnectionOpened cid rel addr -> do
          connMVar <- newEmptyMVar
          forkIO $ do
            Right conn <- connect endpoint addr rel defaultConnectHints
            putMVar connMVar conn 
          go (insert cid connMVar cs) 
        Received cid payload -> do
          forkIO $ do
            conn <- readMVar (cs ! cid)
            send conn payload 
            return ()
          go cs
        ConnectionClosed cid -> do 
          forkIO $ do
            conn <- readMVar (cs ! cid)
            close conn 
          go (delete cid cs) 
        EndPointClosed -> do
          putStrLn "Echo server exiting"
          putMVar serverDone ()
{% endhighlight %}

This implements almost exactly what we described above. The only complication is that we want to avoid blocking the receive queue; so for every message that comes in we spawn a new thread to deal with it. Since is therefore possible that we receive the `Received` event before an outgoing connection has been established, we map connection IDs to MVars containing connections. 

Finally, we need to define `onCtrlC`; `p onCtrlC q` will run `p`; if this is interrupted by Control-C we run `q` and then try again:

{% highlight haskell %}
onCtrlC :: IO a -> IO () -> IO a
p `onCtrlC` q = catchJust isUserInterrupt p (const $ q >> p `onCtrlC` q)
  where
    isUserInterrupt :: AsyncException -> Maybe () 
    isUserInterrupt UserInterrupt = Just ()
    isUserInterrupt _             = Nothing
{% endhighlight %}

### Conclusion

In this tutorial, we have implemented a small echo client and server
to illustrate how the `Network.Transport` abstraction layer can be used.

<!-- would it be possible to have some a sentence or two of commentary here about N.T? -->

See the [`Network.Transport` wiki page](https://github.com/haskell-distributed/distributed-process/wiki/Network.Transport) for more details.

<!-- are there links to other things people who read this tutorial would want to know about? -->
