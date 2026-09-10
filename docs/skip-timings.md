# Where "skip intro" times come from

Scope: `lib/features/skip/`, and the resolution the player drives from
`player_controller.dart`.

An episode gets a skip button when some database can say "the opening runs
from 60s to 150s". Nothing in the catalog carries that, so it is looked up —
and every step of the lookup can fail in a way that looks, from the sofa, like
"skip doesn't work". This is what the chain actually does and why each part of
it is shaped the way it is.

## The chain

1. **A MyAnimeList id.** AniSkip is keyed by it and nothing else. The catalog
   sometimes carries one; when it does not, `MalIdResolver` finds it from the
   title through AniList, Kitsu, ani.zip and Jikan in that order, with the
   answer cached on disk.
2. **AniSkip**, the primary source — crowd-sourced opening and ending times,
   no client id needed, so it works in every build.
3. **ani.zip → IntroDB**, the fallback. IntroDB is keyed by TMDB or IMDb id,
   which no anime source hands out, so ani.zip's mapping table is asked first
   to turn a MyAnimeList id into one. That hop is the only reason IntroDB is
   reachable for anime at all.

## Things that are not obvious

**`episodeLength` is a filter, not a hint.** AniSkip's `episodeLength`
parameter does not scale the timings to your file — it restricts the answer to
submissions timed against a release of that length. Sending the file's own
1440 seconds when the submission was timed against a 1529-second release
returns "not found", even though the timings exist and are perfectly usable.
So the request sends `episodeLength=0`, which means "every submission", and
`AniSkipService` then picks the one whose own length sits closest to the file
being played. `test/features/skip/aniskip_request_test.dart` pins this; if it
starts failing because someone passed the real duration, this is why.

**The MyAnimeList id must be resolved before it is used.** The player falls
back to resolving the id from the title, and that fallback has to run *before*
the skip lookup reads it, not after. Ordering this wrongly produces a lookup
with a null id, which silently returns nothing.

**Kitsu's title search ranks loosely.** `filter[text]=Mao` returns
"Mao Zhi Ming" above the anime actually called Mao, and the endpoint returns
500s intermittently, so it is retried once and treated as unavailable rather
than as a miss when it fails. Some titles — MAO among them — have no MAL
mapping in Kitsu at all, which is what the ani.zip hop is for.

**A failure is not an answer.** Every cache in this area distinguishes "the
service said it has nothing" from "we could not ask". The first is worth
remembering for the hour these caches hold; the second must not be, because
one bad moment at the start of an episode would otherwise hide the skip button
for the rest of the hour with no way to ask again. A 404 counts as an answer.
A 429, a 500 and a dropped connection do not. The same distinction is made in
`ArtworkFallbackService` and `StreamSourcePrefetch` for the same reason.

## What this cannot do

Not every episode has timings. AniSkip is submissions by viewers, so a
just-aired episode of a small show usually has none, and some series have a
single submission for episode 1 and nothing after it. IntroDB covers little
anime beyond what ani.zip can map. When both come back empty the player shows
no button, and that is correct — there is nothing to skip to.

Harbor shows a skip button on some episodes where both of these are empty. Its
sources are the same two plus chapter markers read from the release file
itself and an audio-fingerprint match, which is where the extra coverage comes
from. Neither is implemented here.

## Filler

Filler is a separate idea that shares a screen with this one. The provider
marks episodes as filler; the setting has three positions — off, a note with a
skip button, or skipping automatically — and the "next episode" card and
`nextStoryEpisode` honour it. A season that ends in filler still plays on
rather than stopping dead, since the alternative is refusing to continue.

## Trying it against the real services

`test/features/skip/live_probe_test.dart` resolves a few titles and fetches
their segments for real. It is tagged `live` and excluded from the suite:

```
flutter test test/features/skip/live_probe_test.dart --tags live
```
