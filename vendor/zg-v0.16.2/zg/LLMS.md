# LLMs and `zg`

This library does not have a policy against use of generative AI in
contributions.  I will accept patches which meet my standards, and
my sense of the purpose of `zg`, and do not require disclosure of
method, although you're quite welcome to do so if you'd like.

Releases after `v0.16-rc1` contain code known to have been produced
with the aid of 'agents', as they're colloquially known.  I know this
because those are my commits.  Because of the lack of a disclosure
policy, I cannot state with any confidence that prior releases don't
have such code, only that I did not add any.  I've been making use of
chatbots as part of research and development for quite some time,
however.

If that means you feel you can't use this code for moral reasons, I
understand.  I can't suggest alternatives, because I have no idea of the
status of alternatives with respect to this question, and wouldn't want
to mislead.

If it raises alarms about the possible quality of that code, that much
I can address.  I am always less confident of the correctness of new
code than older code, and you should be as well.  The normalization
refactor passes all of Unicode's tests, which is a reasonable basis
for some confidence, that's why they exist.

The normalization process for caseless search and matching passes those
tests as well, but there isn't a definitive corpus for the match
portion.  That's some of the hardest code in the library, it took
considerable labor and hand editing to get it into a state I felt was
acceptable for release.

It's also not based on anything else[^1].  It follows Unicode's rules,
but in a manner which could be novel, but is in any case original,
in that I did not base it on some other Unicode library.

If you find bugs in `zg`, please open a ticket.  I stand by all the
code in this library: that doesn't mean I offer any guarantees that
it is correct or free of defects, it means that I have been diligent in
preparing it for release.  I'm not the original author of most of `zg`,
and when bugs show up in older code, it's on me to fix that too, unless
someone else is generous enough to do it.  That's always appreciated,
but not required nor even asked for.

Issues intended to change this policy will be closed.

- Sam Atman

[^1]: It's based on this design: https://codeberg.org/atman/zg/issues/80
