---
layout: tutorial1
categories: tutorial
title: Getting Started
---

### Getting Started <a class="pull-right" href="http://hackage.haskell.org/platform" ><img src="http://hackage.haskell.org/platform/icons/button-64.png"></a>

-----

Please note that this tutorial is a work in progress. We highly recommend
reading the haddock documentation and reading the Well-Typed blog, which
are offer the best quality sources of information at this time.

In order to go through this tutorial you will need a Haskell development
environment and we recommend installing the latest version of the
[Haskell Platform](www.haskell.org/platform/) if you've not done
so already.

Once you're up and running, you'll want to get hold of the distributed-process
library and a choice of network transport backend. This guide will use
the network-transport-tcp backend, but the simplelocalnet or inmemory
backends are also available on github, along with some other experimental
options.

### Create a node

Cloud Haskell's *lightweight processes* reside on a 'node', which must
be initialised with a network transport implementation and a remote table.
The latter is required so that physically separate nodes can identify known
objects in the system (such as types and functions) when receiving messages
from other nodes. We'll look at inter-node communication later, so for now
it will suffice to pass the default remote table, which defines the built-in
stuff Cloud Haskell needs at a minimum.

Let's start with imports first:

{% highlight haskell %}
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process
import Control.Distributed.Process.Node
{% endhighlight %}

Our TCP network transport backend needs an IP address and port to get started
with, and we're good to go...

{% highlight haskell %}
main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  ....
{% endhighlight %}

And now we have a running node.

### Send messages

We can start a new lightweight process with `forkProcess`, which takes a node,
a `Process` action - because our concurrent code will run in the `Process`
monad - and returns an address for the process in the form of a `ProcessId`.
The process id can be used to send messages to the running process - here we
will send one to ourselves!

{% highlight haskell %}
-- in main
  _ <- forkProcess node $ do
    -- get our own process id
    self <- getSelfPid
    send self "hello"
    hello <- expect :: Process String
    liftIO $ putStrLn hello
  return ()
{% endhighlight %}

Lightweight processes are implemented as `forkIO` threads. In general we will
try to forget about this implementation detail, but for now just note that we
haven't deadlocked ourself by sending to and receiving from our own mailbox
in this fashion. Sending a message is a completely asynchronous operation - even
if the recipient doesn't exist, no error will be raised and evaluating `send`
will not block the caller.

Receiving messages works the other way around, blocking the caller until a message
matching the expected type arrives in the process (conceptual) mailbox.
If multiple messages of that type are in the queue, they will be returned in FIFO
order, otherwise the caller will be blocked until a message arrives that can be
decoded to the correct type.

Let's spawn another process on the same node and make the two talk to each other.

{% highlight haskell %}
main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  _ <- forkProcess node $ do
      echoPid <- spawnLocal $ forever $ do
          r <- receiveWait [
              match (\((sender :: ProcessId), (msg :: String)) -> send sender msg >> return ())
            , match (\(m :: String) -> say $ "printing " ++ m)
            ]
      -- send some messages!
      self <- getSelfPid
      send (self, "hello")
      m <- expectTimeout 1000000
      case m of
        Nothing  -> die "nothing came back!"
        (Just s) -> say $ "got back " ++ s
{% endhighlight %}

Note that we've used a `receive` class of function this time around. The `match`
construct allows you to construct a list of potential message handlers and
have them evaluated against incoming messages. The first match indicates that,
given a tuple `t :: (ProcessId, String)` that we will send the `String` component
back to the sender's `ProcessId`. The second match prints out whatever string it
receives.

Also note the use of a 'timeout' (given in microseconds), which is available for
both the `expect` and `receive` variants. This returns `Nothing` unless a message
can be dequeued from the mailbox within the specified time interval.

### Serializable

Processes can send data if the type implements the `Serializable` typeclass, which is
done indirectly by implementing `Binary` and deriving `Typeable`. Implementations are
already provided for primitives and some commonly used data structures.

### Spawning Remote Processes

In order to spawn a process on a node we need something of type `Closure (Process ())`.
In distributed-process if `f : T1 -> T2` then

{% highlight haskell %}
  $(mkClosure 'f) :: T1 -> Closure T2
{% endhighlight %}

That is, the first argument the function we pass to mkClosure will act as the closure
environment for that process; if you want multiple values in the closure environment,
you must tuple them up.

In order to spawn a process remotely we will need to configure the remote table
(see the documentation for more details) and the easiest way to do this, is to
let the library generate the relevant code for us. For example (taken from the
distributed-process-platform test suites):

{% highlight haskell %}
sampleTask :: (TimeInterval, String) -> Process String
sampleTask (t, s) = sleep t >> return s

$(remotable ['sampleTask])
{% endhighlight %}

We can now create a closure environment for `sampleTask` like so:

{% highlight haskell %}
($(mkClosure 'sampleTask) (seconds 2, "foobar"))
{% endhighlight %}

The call to `remotable` generates a remote table and generates a definition
`__remoteTable :: RemoteTable -> RemoteTable` in our module for us. We can
compose this with other remote tables in order to come up with a final, merged
remote table for use in our program:

{% highlight haskell %}
myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

main :: IO ()
main = do
 localNode <- newLocalNode transport myRemoteTable
 -- etc
{% endhighlight %}

------

[1]: /static/doc/distributed-process/Control-Distributed-Process.html#v:Message
[2]: http://hackage.haskell.org/package/distributed-process
[3]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Async.html
[4]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-ManagedProcess.htmlv:callAsync
