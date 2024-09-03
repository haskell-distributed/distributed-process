---
layout: page
title: Posts
---
### <a href="/rss.xml"><img src="/img/feed-icon-28x28.png"></a> Posts

<div class="related">
  <ul>
    {% for post in site.posts %}
    <li>
      <span>{{ post.date | date: "%B %e, %Y" }}</span> &middot; <span>{{post.author}}</span> &middot; <span><a href="{% if post.link != null %}{{ post.link }}{% else %}{{ post.url }}{% endif %}">{{ post.title }}</a></span>
    </li>
    {% endfor %}
  </ul>
</div>
