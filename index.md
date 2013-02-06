---
layout: site
title: Home
---
Cloud Haskell: Erlang-style concurrent and distributed programming in Haskell.
The Cloud Haskell Platform consists of a
[generic network transport API](https://github.com/haskell-distributed/network-transport),
libraries for sending [static closures](https://github.com/haskell-distributed/distributed-process-static) to remote nodes, a rich [API for distributed programming](https://github.com/haskell-distributed/distributed-process) and a 
set of [Platform Libraries](https://github.com/haskell-distributed/distributed-process-platform),
modelled after Erlang's [Open Telecom Platform](http://www.erlang.org/doc/).

Generic network transport backends have been developed for
[TCP](https://github.com/haskell-distributed/network-transport-tcp) and
[in-memory](https://github.com/haskell-distributed/network-transport-inmemory)
messaging, and several other implementations are available including a transport for
[Windows Azure](https://github.com/haskell-distributed/distributed-process-azure). The [wiki](/wiki.html) provides links to a number of resources for learning about the conceptual underpinnings of Cloud Haskell, and some [examples](https://github.com/haskell-distributed/distributed-process-demos).

Documentation is available on this site for HEAD, or
[hackage](http://hackage.haskell.org/package/distributed-process) for the current and preceding versions of
each library.

### <a href="/rss.xml"><img src="/img/feed-icon-28x28.png"></a> Recent Activity <a class="pull-right" href="http://hackage.haskell.org/platform" ><img src="http://hackage.haskell.org/platform/icons/button-64.png"></a>

<div class="content">
  <div class="related">
    <ul>
      {% for post in site.posts %}
      <li>
        <span>{{ post.date | date: "%B %e, %Y" }}</span> &middot; <span>{{post.author}}</span> &middot; <span><a href="{% if post.link != null %}{{ post.link }}{% else %}{{ post.url }}{% endif %}">{{ post.title }}</a></span>
      </li>
      {% endfor %}
    </ul>
  </div>
</div>


