# Serving files with Conduit

## Overview

``` haskell
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

import           Data.Aeson
                 (ToJSON, genericToJSON)
import           Data.Maybe
                 (fromMaybe)
import           Data.Proxy
                 (Proxy (..))
import           GHC.Generics
                 (Generic)
import           Servant
                 ((:>), GetPartialContent, Handler, Header, Headers, JSON, Server, addHeader)
import           Servant.Pagination
                 (HasPagination (..), PageHeaders, Range (..), Ranges, RangeOptions(..),
                  applyRange, extractRange, returnRange)

import qualified Data.Aeson               as Aeson
import qualified Network.Wai.Handler.Warp as Warp
import qualified Servant
import qualified Servant.Pagination       as Pagination
```


#### Declaring the Resource

Servant APIs are rather resource-oriented, and so is `servant-pagination`. This
guide shows a basic example working with `JSON` (as you could tell from the
import list already). To make the world a <span style='text-decoration:
line-through'>better</span> colored place, let's create an API to retrieve
colors -- with pagination.

``` haskell
data Color = Color
  { name :: String
  , rgb  :: [Int]
  , hex  :: String
  } deriving (Eq, Show, Generic)

instance ToJSON Color where
  toJSON =
    genericToJSON Aeson.defaultOptions

colors :: [Color]
colors =
  [ Color "Black" [0, 0, 0] "#000000"
  , Color "Blue" [0, 0, 255] "#0000ff"
  , Color "Green" [0, 128, 0] "#008000"
  , Color "Grey" [128, 128, 128] "#808080"
  , Color "Purple" [128, 0, 128] "#800080"
  , Color "Red" [255, 0, 0] "#ff0000"
  , Color "Yellow" [255, 255, 0] "#ffff00"
  ]
```

#### Declaring the Ranges

Now that we have defined our _resource_ (a.k.a `Color`), we are ready to declare a new `Range`
that will operate on a "name" field (genuinely named after the `name` fields from the `Color`
record).
For that, we need to tell `servant-pagination` two things:

- What is the type of the corresponding `Range` values
- How do we get one of these values from our resource

This is done via defining an instance of `HasPagination` as follows:

``` haskell
instance HasPagination Color "name" where
  type RangeType Color "name" = String
  getFieldValue _ = name
  -- getRangeOptions :: Proxy "name" -> Proxy Color -> RangeOptions
  -- getDefaultRange :: Proxy Color  -> Range "name" String

defaultRange :: Range "name" String
defaultRange =
  getDefaultRange (Proxy @Color)
```

Note that `getFieldValue :: Proxy "name" -> Color -> String` is the minimal complete definintion
of the class. Yet, you can define `getRangeOptions` to provide different parsing options (see
the last section of this guide). In the meantime, we've also defined a `defaultRange` as it will
come in handy when defining our handler.

#### API

Good, we have a resource, we have a `Range` working on that resource, we can now declare our
API using other Servant combinators we already know:

``` haskell
type API =
  "colors"
    :> Header "Range" (Ranges '["name"] Color)
    :> GetPartialContent '[JSON] (Headers MyHeaders [Color])

type MyHeaders =
  Header "Total-Count" Int ': PageHeaders '["name"] Color
```

`PageHeaders` is a type alias provided by the library to declare the necessary response headers
we mentionned in introduction. Expanding the alias boils down to the following:

``` haskell
-- type MyHeaders =
--  '[ Header "Total-Count"   Int
--   , Header "Accept-Ranges" (AcceptRanges '["name"])
--   , Header "Content-Range" (ContentRange '["name"] Color)
--   , Header "Next-Range"    (Ranges '["name"] Color)
--   ]
```

As a result, we will need to provide all those headers with the response in our handler. Worry
not, _servant-pagination_ provides an easy way to lift a collection of resources into such handler.

#### Server

Time to connect the last bits by defining the server implementation of our colorful API. The `Ranges`
type we've defined above (tight to the `Range` HTTP header) indicates the server to parse any `Range`
header, looking for the format defined in introduction with fields and target types we have just declared.
If no such header is provided, we will end up receiving `Nothing`. Otherwise, it will be possible
to _extract_ a `Range` from our `Ranges`.

``` haskell
server :: Server API
server = handler
  where
    handler :: Maybe (Ranges '["name"] Color) -> Handler (Headers MyHeaders [Color])
    handler mrange = do
      let range =
            fromMaybe defaultRange (mrange >>= extractRange)

      addHeader (length colors) <$> returnRange range (applyRange range colors)

main :: IO ()
main =
  Warp.run 1442 $ Servant.serve (Proxy @API) server
```

Let's try it out using different ranges to observe the server's behavior. As a reminder, here's
the format we defined, where `<field>` here can only be `name` and `<value>` must parse to a `String`:

- `Range: <field> [<value>][; offset <o>][; limit <l>][; order <asc|desc>]`

Beside the target field, everything is pretty much optional in the `Range` HTTP header. Missing parts
are deducted from the `RangeOptions` that are part of the `HasPagination` instance. Therefore, all
following examples are valid requests to send to our server:

- 1 - `curl http://localhost:1442/colors -vH 'Range: name'`
- 2 - `curl http://localhost:1442/colors -vH 'Range: name; limit 2'`
- 3 - `curl http://localhost:1442/colors -vH 'Range: name Green; order asc; offset 1'`

Considering the following default options:

- `defaultRangeLimit: 100`
- `defaultRangeOffset: 0`
- `defaultRangeOrder: RangeDesc`

The previous ranges reads as follows:

- 1 - The first 100 colors, ordered by descending names
- 2 - The first 2 colors, ordered by descending names
- 3 - The 100 colors after `Green` (not included), ordered by ascending names.


## Going Forward

####  Multiple Ranges

Note that in the simple above scenario, there's no ambiguity with `extractRange` and `returnRange`
because there's only one possible `Range` defined on our resource. Yet, as you've most probably
noticed, the `Ranges` combinator accepts a list of fields, each of which must declare a `HasPagination`
instance. Doing so will make the other helper functions more ambiguous and type annotation are
highly likely to be needed.


``` haskell
instance HasPagination Color "hex" where
  type RangeType Color "hex" = String
  getFieldValue _ = hex

-- to then define: Ranges '["name", "hex"] Color
```


#### Parsing Options

By default, `servant-pagination` provides an implementation of `getRangeOptions` for each
`HasPagination` instance. However, this can be overwritten when defining the instance to provide
your own options. This options come into play when a `Range` header is received and isn't fully
specified (`limit`, `offset`, `order` are all optional) to provide default fallback values for those.

For instance, let's say we wanted to change the default limit to `5` in a new range on
`"rgb"`, we could tweak the corresponding `HasPagination` instance as follows:

``` haskell
instance HasPagination Color "rgb" where
  type RangeType Color "rgb" = Int
  getFieldValue _ = sum . rgb
  getRangeOptions _ _ = Pagination.defaultOptions { defaultRangeLimit = 5 }
```
