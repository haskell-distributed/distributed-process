---
layout: wiki
title: Cloud Haskell Wiki
wiki: Welcome
---

### Welcome

Welcome to the Cloud Haskell Wiki. Navigate to specific pages using the links
on the left. If you wish to edit or add to the pages in this wiki, read on.

### Editing

Editing the wiki is pretty simple. This entire website is stored in a git
repository and its dynamic content rendered by github pages using [Jekyll][1].
You can clone the repository [here][2]. Instructions for using jekyll are
available [online][1], but in general it's just a matter of finding the right
markdown file. Wiki content is all located in the wiki subfolder.

### Adding new content

New wiki pages need to have some specific fields in their [Yaml Front Matter][3].
There is a makefile in the root directory which will create a wiki page for
you (in the wiki directory) and populate the front matter for you. Calling the
makefile is pretty easy.

{% highlight bash %}
make wikipage NAME=<pagename>
{% endhighlight %}

[1]: https://github.com/mojombo/jekyll
[2]: https://github.com/haskell-distributed/haskell-distributed.github.com
[3]: https://github.com/mojombo/jekyll/wiki/YAML-Front-Matter
