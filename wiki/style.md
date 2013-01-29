---
layout: wiki
title: Style Guide
wiki: Style
---

### Style

A lot of this **is** taken from the GHC Coding Style entry [here](http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle).
In particular, please follow **all** the advice on that wiki page when it comes 
to including comments in your code.

I am also grateful to @tibbe for his
[haskell-style-guide](https://github.com/tibbe/haskell-style-guide), from
which some of these rules have been taken.

As a general rule, stick to the same coding style as is already used in the file 
you're editing. It **is** much better to write code that is transparent than to 
write code that is short. Please don't assume everyone is a minimalist - self
explanatory code is **much** better in the long term than pithy one-liners.
Having said that, we *do* like reusing abstractions where doing so adds to the
clarity of the code as well as minimising repetitious boilerplate.

### Formatting

#### Line Length

Maximum line length is *80 characters*. This might seem antiquated
to you, but some of us do things like github pull-request code
reviews on our mobile devices on the way to work, and long lines
make this horrendously difficult. Besides which, some of us are
also emacs users and have this rule set up for all of our source
code editing modes.

#### Indentation

Tabs are illegal. Use **only** spaces for indenting.
Indentation is usually 2 spaces, with 4 spaces used in some places.
We're pretty chilled about this, but try to remain consistent.

#### Blank Lines

One blank line between top-level definitions.  No blank lines between
type signatures and function definitions.  Add one blank line between
functions in a type class instance declaration if the functions bodies
are large. As always, use your judgement.

#### Whitespace

Do not introduce trailing whitespace. If you find trailing whitespace,
feel free to strip it out - in a separate commit of course!

Surround binary operators with a single space on either side.  Use
your better judgement for the insertion of spaces around arithmetic
operators but always be consistent about whitespace on either side of
a binary operator.

#### Alignment

When it comes to alignment, there's probably a mix of things in the codebase
right now. Personally, I tend not to align import statements as these change
quite frequently and it is pain keeping the indentation consistent.

The one exception to this is probably imports/exports, which we *are* a
bit finicky about: 

{% highlight haskell %}
import qualified Foo.Bar.Baz as Bz
import Data.Binary
  ( Binary (..),
  , getWord8
  , putWord8
  )
import Data.Blah
import Data.Boom (Typeable)
{% endhighlight %}

Personally I don't care *that much* about alignment for other things,
but as always, try to follow the convention in the file you're editing
and don't change things just for the sake of it.

### Comments

#### Punctuation

Write proper sentences; start with a capital letter and use proper
punctuation.

#### Top-Level Definitions

Comment every top level function (particularly exported functions),
and provide a type signature; use Haddock syntax in the comments.
Comment every exported data type.  Function example:

{% highlight haskell %}
-- | Send a message on a socket.  The socket must be in a connected
-- state.  Returns the number of bytes sent.  Applications are
-- responsible for ensuring that all data has been sent.
send :: Socket      -- ^ Connected socket
     -> ByteString  -- ^ Data to send
     -> IO Int      -- ^ Bytes sent
{% endhighlight %}

For functions the documentation should give enough information to
apply the function without looking at the function's definition.

### Naming

Use `mixedCase` when naming functions and `CamelCase` when naming data
types.

For readability reasons, don't capitalize all letters when using an
abbreviation.  For example, write `HttpServer` instead of
`HTTPServer`.  Exception: Two letter abbreviations, e.g. `IO`.

#### Modules

Use singular when naming modules e.g. use `Data.Map` and
`Data.ByteString.Internal` instead of `Data.Maps` and
`Data.ByteString.Internals`.
