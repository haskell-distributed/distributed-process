---
layout: changes
title: Changelog
---

### Viewing Changes

Each version of each cloud haskell project has a change log, which can be
viewed by clicking on the links to the left hand side of this page.

### Editing

Editing this page is pretty simple. This entire website is stored in a git
repository and its dynamic content rendered by github pages using [Jekyll][1].
You can clone the repository [here][2]. Instructions for using jekyll are
available [online][1], but in general it's just a matter of finding the right
markdown file. Wiki content is all located in the wiki subfolder.

### Adding new content

We plan to set up a script that pulls the Jira RSS feed and inserts content
here, however for the time being, adding a new page beneath the `changelog`
folder will be sufficient to pull a new version into the navigation menu.
Our Jira instance is set up to produce HTML release notes which can be tweaked
by hand if necessary and the front matter for change-logs can be copied from
one of the existing pages.


[1]: https://github.com/mojombo/jekyll
[2]: https://github.com/haskell-distributed/haskell-distributed.github.com
[3]: https://github.com/mojombo/jekyll/wiki/YAML-Front-Matter
