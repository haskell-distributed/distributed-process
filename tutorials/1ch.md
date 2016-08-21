---
layout: tutorial
categories: tutorial
sections: ['Getting Started', 'Creating a node', 'Sending messages', 'Spawning Remote Processes']
title: 1. Getting Started
---

### Getting Started

-----

In order to go through this tutorial, you will need a working Haskell
environment. If you don't already have one follow the instructions
[here](https://www.haskell.org/downloads) to install the compiler and
then
[go here](https://github.com/commercialhaskell/stack/wiki/Downloads)
to install `stack`, a popular build tool for Haskell projects.

Once you're up and running, you'll want to get hold of the
`distributed-process` library and a choice of network transport
backend. This guide will use the `network-transport-tcp` backend, but
other backends are available on [Hackage](https://hackage.haskell.org)
and [GitHub](https://github.com).

### Setting up the project

Starting a new Cloud Haskell project using `stack` is as easy as

{% highlight bash %}
$ stack new
{% endhighlight %}

in a fresh new directory. This will populate the directory with
a number of files, chiefly `stack.yaml` and `*.cabal` metadata files
for the project. You'll want to add `distributed-process` and
`network-transport-tcp` to the `build-depends` stanza of the
executable section.

### Creating a node

Cloud Haskell's *lightweight processes* reside on a "node", which must
be initialised with a network transport implementation and a remote table.
The latter is required so that physically separate nodes can identify known
objects in the system (such as types and functions) when receiving messages
from other nodes. We will look at inter-node communication later, for now
it will suffice to pass the default remote table, which defines the built-in
types that Cloud Haskell needs at a minimum in order to run.

In `app/Main.hs`, we start with our imports:

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

We start a new process by evaluating `runProcess`, which takes a node and
a `Process` action to run, because our concurrent code will run in the
`Process` monad. Each process has an identifier associated to it. The process
id can be used to send messages to the running process - here we will send one
to ourselves!

{% highlight haskell %}
-- in main
  _ <- runProcess node $ do
    -- get our own process id
    self <- getSelfPid
    send self "hello"
    hello <- expect :: Process String
    liftIO $ putStrLn hello
  return ()
{% endhighlight %}

Note that we haven't deadlocked our own thread by sending to and receiving
from its mailbox in this fashion. Sending messages is a completely
asynchronous operation - even if the recipient doesn't exist, no error will be
raised and evaluating `send` will not block the caller, even if the caller is
sending messages to itself.

Each process also has a *mailbox* associated with it. Messages sent to
a process are queued in this mailbox. A process can pop a message out of its
mailbox using `expect` or the `receive*` family of functions. If no message of
the expected type is in the mailbox currently, the process will block until
there is. Messages in the mailbox are ordered by time of arrival.

Let's spawn two processes on the same node and have them talk to each other:

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
  runProcess node $ do
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
      Just s -> say $ "got " ++ s ++ " back!"
      
    -- Without the following delay, the process sometimes exits before the messages are exchanged.
    liftIO $ threadDelay 2000000
{% endhighlight %}

Note that we've used `receiveWait` this time around to get a message.
`receiveWait` and similarly named functions can be used with the
[`Match` data type][5] to provide a range of advanced message
processing capabilities. The `match` primitive allows you to construct
a "potential message handler" and have it evaluated against received
(or incoming) messages. Think of a list of `Match`es as the
distributed equivalent of a pattern match. As with `expect`, if the
mailbox does not contain a message that can be matched, the evaluating
process will be blocked until a message arrives which _can_ be
matched.

In the _echo server_ above, our first match prints out whatever string it
receives. If the first message in our mailbox is not a `String`, then our
second match is evaluated. Thus, given a tuple `t :: (ProcessId, String)`, it
will send the `String` component back to the sender's `ProcessId`. If neither
match succeeds, the echo server blocks until another message arrives and tries
again.

### Serializable Data

Processes may send any datum whose type implements the `Serializable`
typeclass, defined as:

{% highlight haskell %}
class (Binary a, Typeable) => Serializable a
instance (Binary a, Typeable a) => Serializable a
{% endhighlight %}

That is, any type that is `Binary` and `Typeable` is `Serializable`. This is
the case for most of Cloud Haskell's primitive types as well as many standard
data types. For custom data types, the `Typeable` instance is always
given by the compiler, and the `Binary` instance can be auto-generated
too in most cases, e.g.:

{% highlight haskell %}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

data T = T Int Char deriving (Generic, Typeable)

instance Binary T
{% endhighlight %}


### Spawning Remote Processes

We saw above that the behaviour of processes is determined by an action in the
`Process` monad. However, actions in the `Process` monad, no more serializable
than actions in the `IO` monad. If we can't serialize actions, then how can we
spawn processes on remote nodes?

The solution is to consider only *static* actions and compositions thereof.
A static action is always defined using a closed expression (intuitively, an
expression that could in principle be evaluated at compile-time since it does
not depend on any runtime arguments). The type of static actions in Cloud
Haskell is `Closure (Process a)`. More generally, a value of type `Closure b`
is a value that was constructed explicitly as the composition of symbolic
pointers and serializable values. Values of type `Closure b` are serializable,
even if values of type `b` might not be. For instance, while we can't in general
send actions of type `Process ()`, we can construct a value of type `Closure
(Process ())` instead, containing a symbolic name for the action, and send
that instead. So long as the remote end understands the same meaning for the
symbolic name, this works just as well. A remote spawn then, takes a static
action and sends that across the wire to the remote node.

Static actions are not easy to construct by hand, but fortunately Cloud
Haskell provides a little bit of Template Haskell to help. If `f :: T1 -> T2`
then

{% highlight haskell %}
  $(mkClosure 'f) :: T1 -> Closure T2
{% endhighlight %}

You can turn any top-level unary function into a `Closure` using `mkClosure`.
For curried functions, you'll need to uncurry them first (i.e. "tuple up" the
arguments). However, to ensure that the remote side can adequately interpret
the resulting `Closure`, you'll need to add a mapping in a so-called *remote
table* associating the symbolic name of a function to its value. Processes can
only be successfully spawned on remote nodes if all these remote nodes have
the same remote table as the local one.

We need to configure our remote table (see the [API reference][6] for
more details) and the easiest way to do this, is to let the library
generate the relevant code for us. For example:

{% highlight haskell %}
sampleTask :: (TimeInterval, String) -> Process ()
sampleTask (t, s) = sleep t >> say s

remotable ['sampleTask]
{% endhighlight %}

The last line is a top-level Template Haskell splice. At the call site for
`spawn`, we can construct a `Closure` corresponding to an application of
`sampleTask` like so:

{% highlight haskell %}
($(mkClosure 'sampleTask) (seconds 2, "foobar"))
{% endhighlight %}

The call to `remotable` implicitly generates a remote table by inserting
a top-level definition `__remoteTable :: RemoteTable -> RemoteTable` in our
module for us. We compose this with other remote tables in order to come up
with a final, merged remote table for all modules in our program:

{% highlight haskell %}
{-# LANGUAGE TemplateHaskell #-}

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Network.Transport.TCP (createTransport, defaultTCPParameters)

sampleTask :: (Int, String) -> Process ()
sampleTask (t, s) = liftIO (threadDelay (t * 1000000)) >> say s

remotable ['sampleTask]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "10501" defaultTCPParameters
  node <- newLocalNode transport myRemoteTable
  runProcess node $ do
    us <- getSelfNode
    _ <- spawnLocal $ sampleTask (1 :: Int, "using spawnLocal")
    pid <- spawn us $ $(mkClosure 'sampleTask) (1 :: Int, "using spawn")
    liftIO $ threadDelay 2000000
{% endhighlight %}

In the above example, we spawn `sampleTask` on node `us` in two
different ways:

* using `spawn`, which expects some node identifier to spawn a process
  on along for the action of the process.
* using `spawnLocal`, a specialization of `spawn` to the case when the
  node identifier actually refers to the local node (i.e. `us`). In
  this special case, no serialization is necessary, so passing an
  action directly rather than a `Closure` works just fine.

------

[1]: /static/doc/distributed-process/Control-Distributed-Process.html#v:Message
[2]: http://hackage.haskell.org/package/distributed-process
[3]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Async.html
[4]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-ManagedProcess.htmlv:callAsync
[5]: http://hackage.haskell.org/packages/archive/distributed-process/latest/doc/html/Control-Distributed-Process-Internal-Primitives.html#t:Match
[6]: http://hackage.haskell.org/packages/archive/distributed-process/latest/doc/html/Control-Distributed-Process-Closure.html
