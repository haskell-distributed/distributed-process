---
layout: tutorial
categories: tutorial
sections: ['Getting Started', 'Installing from source', 'Creating a node', 'Sending messages', 'Spawning Remote Processes']
title: Getting Started
---

### Getting Started

-----

In order to go through this tutorial, you will need a Haskell development
environment and we recommend installing the latest version of the
[Haskell Platform](http://www.haskell.org/platform/) if you've not done
so already.

Once you're up and running, you'll want to get hold of the distributed-process
library and a choice of network transport backend. This guide will use
the network-transport-tcp backend, but other backends may be available
on github.

### Installing from source

If you're installing from source, the simplest method is to checkout the
[Umbrella Project](https://github.com/haskell-distributed/cloud-haskell) and
run `make` to obtain the complete set of source repositories for building
Cloud Haskell. The additional makefiles bundled with the umbrella assume
that you have a recent version of cabal (with support for sandboxes) installed.

### Creating a node

Cloud Haskell's *lightweight processes* reside on a "node", which must
be initialised with a network transport implementation and a remote table.
The latter is required so that physically separate nodes can identify known
objects in the system (such as types and functions) when receiving messages
from other nodes. We will look at inter-node communication later, for now
it will suffice to pass the default remote table, which defines the built-in
types that Cloud Haskell needs at a minimum in order to run.

We start with our imports:

{% highlight haskell %}
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process
import Control.Distributed.Process.Node
{% endhighlight %}

Our TCP network transport backend needs an IP address and port to get started
with:

{% highlight haskell %}
main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  ....
{% endhighlight %}

And now we have a running node.

### Sending messages

We start a new process by evaluating `forkProcess`, which takes a node,
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
try to forget about this implementation detail, but let's note that we
haven't deadlocked our own thread by sending to and receiving from its mailbox
in this fashion. Sending messages is a completely asynchronous operation - even
if the recipient doesn't exist, no error will be raised and evaluating `send`
will not block the caller, even if the caller is sending messages to itself!

Receiving works the opposite way, blocking the caller until a message
matching the expected type arrives in our (conceptual) mailbox. If multiple
messages of that type are present in the mailbox, they're be returned in FIFO
order, if not, the caller is blocked until a message arrives that can be
decoded to the correct type.

Let's spawn two processes on the same node and have them talk to each other.

{% highlight haskell %}
import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Network.Transport.TCP (createTransport, defaultTCPParameters)

replyBack :: (ProcessId, String) -> Process ()
replyBack (sender, msg) = send sender msg

logMessage :: String -> Process ()
logMessage msg = say $ "handling " ++ msg

main :: IO ()
main = do
  Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  forkProcess node $ do
    -- Spawn another worker on the local node 
    echoPid <- spawnLocal $ forever $ do
      -- Test our matches in order against each message in the queue
      receiveWait [match logMessage, match replyBack]

    -- The `say` function sends a message to a process registered as "logger".
    -- By default, this process simply loops through its mailbox and sends
    -- any received log message strings it finds to stderr.

    say "send some messages!"
    send echoPid "hello"
    self <- getSelfPid
    send echoPid (self, "hello")

    -- `expectTimeout` waits for a message or times out after "delay"
    m <- expectTimeout 1000000
    case m of
      -- Die immediately - throws a ProcessExitException with the given reason.
      Nothing  -> die "nothing came back!"
      (Just s) -> say $ "got " ++ s ++ " back!"
    return ()

  -- A 1 second wait. Otherwise the main thread can terminate before
  -- our messages reach the logging process or get flushed to stdio
  liftIO $ threadDelay (1*1000000)
  return ()
{% endhighlight %}

Note that we've used the `receive` class of functions this time around.
These can be used with the [`Match`][5] data type to provide a range of
advanced message processing capabilities. The `match` primitive allows you
to construct a "potential message handler" and have it evaluated
against received (or incoming) messages. As with `expect`, if the mailbox does
not contain a message that can be matched, the evaluating process will be
blocked until a message arrives which _can_ be matched.

In the _echo server_ above, our first match prints out whatever string it
receives. If first message in out mailbox is not a `String`, then our second
match is evaluated. This, given a tuple `t :: (ProcessId, String)`, will send
the `String` component back to the sender's `ProcessId`. If neither match
succeeds, the echo server blocks until another message arrives and
tries again.

### Serializable Data

Processes may send any datum whose type implements the `Serializable` typeclass,
which is done indirectly by deriving `Binary` and `Typeable`. Implementations are 
provided for most of Cloud Haskell's primitives and various common data types.

### Spawning Remote Processes

In order to spawn processes on a remote node without additional compiler
infrastructure, we make use of "static values": values that are known at
compile time. Closures in functional programming arise when we partially
apply a function. In Cloud Haskell, a closure is a code pointer, together
with requisite runtime data structures representing the value of any free
variables of the function. A remote spawn therefore, takes a closure around
an action running in the `Process` monad: `Closure (Process ())`.

In distributed-process if `f : T1 -> T2` then

{% highlight haskell %}
  $(mkClosure 'f) :: T1 -> Closure T2
{% endhighlight %}

That is, the first argument to the function we pass to mkClosure will act
as the closure environment for that process. If you want multiple values
in the closure environment, you must "tuple them up".

We need to configure our remote table (see the documentation for more details)
and the easiest way to do this, is to let the library generate the relevant
code for us. For example (taken from the distributed-process-platform test suites):

{% highlight haskell %}
sampleTask :: (TimeInterval, String) -> Process String
sampleTask (t, s) = sleep t >> return s

$(remotable ['sampleTask])
{% endhighlight %}

We can now create a closure environment for `sampleTask` like so:

{% highlight haskell %}
($(mkClosure 'sampleTask) (seconds 2, "foobar"))
{% endhighlight %}

The call to `remotable` generates a remote table and a definition
`__remoteTable :: RemoteTable -> RemoteTable` in our module for us.
We compose this with other remote tables in order to come up with a
final, merged remote table for use in our program:

{% highlight haskell %}
myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

main :: IO ()
main = do
 localNode <- newLocalNode transport myRemoteTable
 -- etc
{% endhighlight %}

Note that we're not limited to sending `Closure`s - it is possible to send data
without having static values, and assuming the receiving code is able to decode
this data and operate on it, we can easily put together a simple AST that maps
to operations we wish to execute remotely.

------

[1]: /static/doc/distributed-process/Control-Distributed-Process.html#v:Message
[2]: http://hackage.haskell.org/package/distributed-process
[3]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Async.html
[4]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-ManagedProcess.htmlv:callAsync
[5]: http://hackage.haskell.org/packages/archive/distributed-process/latest/doc/html/Control-Distributed-Process-Internal-Primitives.html#t:Match
