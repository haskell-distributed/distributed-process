---
layout: tutorial
categories: tutorial
sections: ['Overview', 'A Simple Example', 'Master Slave Configurations', 'Other Topologies and Backends']
title: Managing Topologies
---

### Overview

In Cloud Haskell, the system topology is determined by your choice of _Cloud Haskell Backend_.
The basic topology that Cloud Haskell currently ships with is determined by the
[`simplelocalnet`][1] backend, which provides for a fully connected grid of nodes with optional
master-slave configuration. This backend allows nodes to discover one another using UDP multicast.
It is a zero-configuration backend designed to get you going with Cloud Haskell quickly without
imposing any particular structure on your application.

Other backends might work in a completely different manner, offering different types of (and
relationships between) nodes, or simply by handling discovery differently (e.g., pre-defined
node names/addresses, or by using some form of registrar such as DNS-SD/Bonjour).

### A Simple Example

Here is an example program built against the [`simplelocalnet`][1] backend, that periodically
searches for a list of peer nodes, and sends a message to a registered (named) process on each.

{% highlight haskell %}
import System.Environment (getArgs)
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Monad (forever, mapM_)

main = do
  [host, port] <- getArgs
  
  backend <- initializeBackend host port initRemoteTable
  node    <- newLocalNode backend
  runProcess node $ forever $ do
    findPeers backend >>= mapM_ $ \peer -> nsendRemote peer "echo-server" "hello!"

{% endhighlight %}

Clearly the program isn't very useful, but it illustrates the two key concepts that
`simplelocalnet` relies on. Firstly, that we `initializeBackend` in order to get
connected to an underlying communications infrastructure and secondly, that we can
evaluate `findPeers` at any time to obtain the set of other nodes that have broadcast
their presence.

### Master Slave Configurations

Here we simply rehash the master/slave example from the `simplelocalnet` documentation.
With the same imports as the example above, we add a no-op slave and a master that
takes a list of its (known) slaves, which it prints out before terminating them all.

{% highlight haskell %}
main :: IO ()
main = do
  args <- getArgs

  case args of
    ["master", host, port] -> do
      backend <- initializeBackend host port initRemoteTable
      startMaster backend (master backend)
    ["slave", host, port] -> do
      backend <- initializeBackend host port initRemoteTable
      startSlave backend

{% endhighlight %}

And the master node is defined thus:

{% highlight haskell %}
master :: Backend -> [NodeId] -> Process ()
master backend slaves = do
  -- Do something interesting with the slaves
  liftIO . putStrLn $ "Slaves: " ++ show slaves
  -- Terminate the slaves when the master terminates (this is optional)
  terminateAllSlaves backend
{% endhighlight %}

### Other Topologies and Backends

Many other topologies are in development, including one that runs on Windows Azure,
which is available [here][2]. Some third party backends have also been developed,
such as the [`distributed-process-p2p`][3] backend, which given a known node address,
discovers and maintains knowledge of it's peers.

Here is an example of node discovery using the [`distributed-process-p2p`][3]
backend:

{% highlight haskell %}
import System.Environment (getArgs)
import Control.Distributed.Process
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.P2P
import Control.Monad (forever, mapM_)

main = do
  [host, port] <- getArgs
  
  backend <- initializeBackend host port initRemoteTable
  node    <- newLocalNode backend
  runProcess node $ forever $ do
    findPeers >>= mapM_ $ \peer -> nsend peer "echo-server" "hello!"

{% endhighlight %}

[1]: http://hackage.haskell.org/package/distributed-process-simplelocalnet
[2]: http://hackage.haskell.org/package/distributed-process-azure
[3]: https://bitbucket.org/dpwiz/distributed-process-p2p

