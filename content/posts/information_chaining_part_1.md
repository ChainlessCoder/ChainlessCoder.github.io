---
author: Lum Ramabaja
title: "Let It Bloom: The Seeds of Information Chaining (Part 1)"
date: 2026-01-19
draft: false
math: true
description: "Let It Bloom: The Seeds of Information Chaining (Part 1)"
summary: "An exploration of how Bloom filters can be used to design Information Chaining-based erasure codes."
tags: [
   Open Cybernetics, Information Chaining, Bloom Filter, Erasure Code
   ]
series: ["Open Cybernetics"]
---

{{< banner src="/images/information_chaining_part_1/banner.jpg" alt="Let it Bloom" >}}

---
<!--more-->

“Information Chaining” is a new family of erasure codes developed at [Open Cybernetics](https://opencybernetics.io). Some variants are rateless; others are fixed-rate. In this series, we’ll explore the different *flavors* of Information Chaining. While later versions are substantially more performant and no longer rely on approximate membership query (AMQ) filters, we begin with the Bloom filter–based variant because it offers the most intuitive entry point into the core idea. It’s also how the concept originally came about.

Throughout the series, I’ll include examples written in [Zig](https://ziglang.org/) (version `0.15.2`). All the code shown here is open source; you can find it in the blog’s GitHub [repository](https://github.com/ChainlessCoder/ChainlessCoder.github.io/tree/main/code_examples/zig/information_chaining_part_1/src). If you’d like to learn more about our work and philosophy, visit [our blog](https://blog.opencybernetics.io/post/who_holds_the_control/). And if Zig sparks joy for you the way it does for us, consider supporting the [Zig Software Foundation](https://ziglang.org/zsf/).


# Bloom Filters

Before we continue, let’s refresh our understanding of what Bloom filters are and how they work. A Bloom filter is a simple, space-efficient probabilistic data structure that allows us to quickly test whether an element is part of a set. Initialization is straightforward: we define a bit array of size $m$, initialized with all bits set to zero, and select $k$ independent hash functions. These hash functions don’t need to be cryptographically secure, just fast and reasonably uniform. To populate a Bloom filter, we perform the following steps:

- Hash an element using the $k$ hash functions, generating $k$ hashes.
- Take each hash modulo $m$ to ensure the resulting values fall within the range `[0, m)`.
- Use these $k$ values as indices into the bit array, setting the bits at those positions from `0` to `1` (see Figure 1).
- Repeat the process for each element to be inserted.

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/bloom_filter_1.svg">
 <em><br/>Figure 1. Adding an element to a Bloom filter.</em>
</p>

To check whether an element is present, we hash it $k$ times and look up the corresponding bits. If any of the $k$ bits is `0`, we can be certain that the element was never inserted, this is why false negatives are impossible in a Bloom filter. However, this efficiency comes at a cost: the structure is probabilistic. While Bloom filters can never produce false negatives, they *can* produce false positives, cases where the filter indicates that an element *might* be in the set, even when it isn’t.

To see how this happens, let’s look at Figure 2. Here, elements $Y$ and $Z$ have been added to the filter. Checking for them shows that all corresponding bits are set to `1`, so we correctly conclude that they’re present. But if we check for element $X$, which was never inserted, we might find that its $k$ bit positions are also all `1`, not because $X$ was added, but because its indices overlap with those of $Y$ and $Z$. That overlap leads to a false positive.

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/bloom_filter_2.svg">
 <em><br/>Figure 2. A depiction of a false positive match during a Bloom filter lookup.</em>
</p>

Fortunately, the false positive rate can be controlled by adjusting the Bloom filter’s parameters:

$$p = \left(1-\left(1-\frac{1}{m}\right)^{kn}\right)^k \approx \left(1-e^{-\frac{kn}{m}} \right)^k$$

Here:
- $n$ = number of inserted elements  
- $m$ = number of bits in the filter  
- $k$ = number of hash functions

We can reduce the false positive rate $p$ by increasing $m$ and $k$, or by decreasing $n$. The optimal values for $m$ and $k$, given a target false positive rate $p$ and element count $n$, are derived as:


$$ m = -\frac{n\ln(p)}{\ln(2)^2}; \qquad k = \frac{m}{n}\ln(2) $$

While the derivation of these formulas is elegant, it’s also a bit math-heavy. If you’d like to dive into the derivation, see the [Wikipedia section](https://en.wikipedia.org/wiki/Bloom_filter#Probability_of_false_positives) on Bloom filter false positives.

For the hands-on reader, I’ve included a special Bloom filter implementation in Zig (*Code Example 1*). This version isn’t a conventional Bloom filter and isn’t optimized for performance. Unlike the standard algorithm, it has a strange way to insert items. The reason for this unusual design choice will become clear in the next section.


{{< readfile file="code_examples/zig/information_chaining_part_1/src/simplified_filter.zig" lang="zig" title="Code Example 1. Simplified Bloom Filter">}}


# The Seeds of Information Chaining

Let us now tinker.

We know that we can insert elements into a Bloom filter and then check, in a space-efficient way, whether an element *might* be in it. These cheap lookups are used everywhere, in databases (LSM trees), in set reconciliation, in the Bitcoin protocol, in genomics (k-mer lookups), and more. But what if we go beyond space-efficient *lookups*? What if we could not only verify the absence of elements via Bloom filters, but also store data within them, effectively encoding information into a Bloom filter, and later decoding it back to its original form? Why would we even want to do that? For now, let’s not worry about the *why*. We’re just tinkering. The *why* will reveal itself soon.


## Encoding data into a Bloom filter

How might we encode an entire sequence of symbols into a Bloom filter? A natural first attempt might be to insert each symbol of the sequence into the Bloom filter. But that alone doesn’t capture order or repetition. A second idea could be to insert each symbol together with its index position. That’s better, but not enough. Because Bloom filters are probabilistic, collisions will occur: depending on the false positive rate and bit size, several symbols might appear to belong to the same position. Without prior knowledge of the input distribution, we couldn’t reliably recover the original message. No, we need something different. Something cleaner.

To keep things simple, let’s treat each bit of the original message as a separate symbol (We’ll deal with multi-bit symbols later). Now, in all Bloom filter variants, one thing is constant: each lookup is independent. If we inserted symbols along with their index positions, checking whether the bit at position $N$ is present would tell us nothing about the bit at position $N + 1$. But what if we could turn those independent probabilities into conditional probabilities? *What if we "chain" the insertions*? This simple realization is the seed for Information Chaining.


Let’s walk through *Code Example 2* to understand how encoding works in a Bloom filter–based Information Chaining implementation. Imagine a state machine with an initial state, a *nonce*, which could be a random value, a counter, an empty state, or something derived from a public key. We’ll refer to the current state of this machine as the chain header. For simplicity, we’ll treat it as a `usize` for now; later, we’ll explore how its type influences performance and behavior. We then iterate over the message and perform the following steps:

1. Take the current source symbol (a bit) of the message that we want to encode.  
2. Update the chain header by mixing the current chain header with the symbol. Any fast, random-looking mixing function will do, the goal is to evolve the state unpredictably.  
3. Insert the new chain header into the simplified filter, turning the corresponding bit(s) from `0` to `1`.

After processing all the source symbols, we end up with a populated filter that represents an encoding.

{{< readfile file="code_examples/zig/information_chaining_part_1/src/encoder_prototype.zig" lang="zig" title="Code Example 2. Information Chaining Encoder">}}


## Decoding: finding the correct path

To retrieve the original message, we iteratively reconstruct it from left to right. We start by checking the presence of the *first symbol* (bit) in the Bloom filter. Because each bit could be either `0` or `1`, we perform two lookups. Due to false positives, both might appear present. If so, we must keep *both* as potential candidates, one is right, one is wrong, but we don’t yet know which.

If only `1` appears present, then in the next iteration we perform lookups only for sequences continuing from that known prefix.  For example, if the first bit is confirmed as `1`, then we only check for chain headers corresponding to segments `10` and `11`, skipping `00` and `01`. If both `0` and `1` remain possible after the first iteration, we must explore four states in the next: `00`, `01`, `10`, and `11`. At first glance, this might seem to explode into $2^N$ lookups for an $N$-bit message, but it turns out the math is on our side.

### Paths, trees, and probabilities

Let’s clarify some terminology. We call a candidate sequence that matches the true message the "**correct path**". All other candidates are "**wrong paths**". You can visualize the decoding process as an *expanding binary tree*, where the tree depth corresponds to the message length. We begin at the root (the initial chain header) and, at each step, check whether branch `0` or branch `1` exists in the Bloom filter. As we traverse, the tree grows. The original message, the correct path, corresponds to one specific route through this tree (see Figure 3). False positives cause additional branches to appear (Figure 4). The goal of decoding is to efficiently recover the correct path hidden among exponentially many candidates, a message buried in a haystack of false positives.

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/correct_path.svg">
 <em><br/>Figure 3. The message can be imagined as a path through the binary tree of the decoding process. This path is also referred to as the correct path. The goal of decoding is to iteratively recover the correct path.</em>
</p>

If every lookup had the same probability of success, our attempt to decode the sequence would be futile, the number of wrong paths would quickly explode. But in Information Chaining, not all lookups are equal. The probability that a *correct-path segment* appears present is always 1, since it was actually inserted. For *wrong paths*, the first bit has probability $p$ (the Bloom filter’s false positive rate). At depth 2, that probability becomes $p^2$; at depth 3, $p^3$; and so on. Why? Because our lookups are no longer independent. The presence of each lookup depends on the previous ones. If $p = 0.1$, then the next level’s false positive rate becomes $0.01$. As long as $p < 0.5$, wrong paths are pruned faster than they’re created. This prevents the exponential blowup and keeps the decoding process tractable. **Voilà, probabilistic Information Chaining!**

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/branching.svg">
 <em><br/>Figure 4. False positives cause branching during decoding. Because of the conditional structure of Information Chaining, wrong paths are pruned over time.</em>
</p>

### Why the false positive rate matters

In Information Chaining, each symbol’s mapping onto the Bloom filter depends on all *previous* symbols, transforming independent probabilities into conditional ones. But why must the false positive rate be below 0.5? The number of potential decoding paths depends directly on $p$. If $p = 0.5$, then at depth 16 the false positive probability for a symbol is $0.5^{16} = 0.0000152587890625$. That sounds small, but a binary tree of depth 16 has $2^{16} = 65,536$ paths, and $65,536 \times 0.0000152587890625 = 1$. In other words, the number of potential paths grows linearly with depth. Not ideal.

We want the expected number of paths multiplied by their probability to stay slightly below 1. That ensures decoding remains efficient without exponential growth. If $p$ is a bit smaller, say 0.48, something remarkable happens: the number of potential paths doesn’t grow linearly or even logarithmically, it converges to a fixed number. The expected number of paths is given by:

$$1 + \sum_{i=0}^{n} 2^{i} p^{i+1}$$

Let’s unpack this (see Figure 5). During decoding, the correct path and all of its subpaths are guaranteed to appear. Each symbol along that path can spawn a wrong branch with probability $p$. Breaking down the formula:

- The **1** represents the correct path.  
- The **$2^i$** term counts the number of leaf nodes in a branch (e.g., branch A has $2^0 = 1$, branch B has $2^1 = 2$, etc.).  
- The **$p^{i+1}$** term captures the probability that a wrong branch of depth $i + 1$ remains fully “alive” (i.e., unpruned).

The further a wrong path strays from the correct one, the less likely it is to survive. Early iterations may branch aggressively, but older ones quickly converge toward the single correct path. That's why the candidate paths in *Code Example 3* don't have to store the entire decoded message. to re-emphesize: wrong paths that split earlier from the correct path during decoding have a significantly smaller chance of "survival" with each new iteration compared to wrong paths that split up more recently from the correct path. Only the most recent symbols (bits) of the candidate paths differ. That's all the data that needs to be stored per candidate path.

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/expected_wrong_paths.svg">
 <em><br/>Figure 5. Wrong branches (A, B, C, D) at various depths. Each branch’s survival probability decreases exponentially with distance from the correct path.</em>
</p>

{{< readfile file="code_examples/zig/information_chaining_part_1/src/decoder_prototype.zig" lang="zig" title="Code Example 3. Information Chaining Decoder Prototype">}}

Figure 6 shows how the false positive rate affects the expected number of decoding paths for a one-million-bit message. As $p$ decreases, the expected number of paths, and thus the decoding effort, drops sharply. Fewer paths mean faster decoding. You might wonder: why not simply choose a very small $p$, like 0.01, and enjoy near-instant decoding? Because reducing $p$ also increases the Bloom filter’s size. Figure 7 illustrates this trade-off. Lowering $p$ reduces time overhead but increases space overhead. The ideal balance between the two depends on the application.

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/fpr_to_paths.svg">
 <em><br/>Figure 6. Relationship between false positive rate and expected number of potential paths during decoding.</em>
</p>

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/fpr_to_bf_m.svg">
 <em><br/>Figure 7. Bloom filter size as a function of false positive rate.</em>
</p>


# From Chaining to Erasure Coding 

**If you've come this far, it's time to finally talk about the why.**

Imagine you’re a sender who needs to reliably transmit a series of data packets to a receiver over the Internet. What’s the fastest and most reliable way to do it? The most naïve method would be a connectionless approach (e.g., using UDP), transmitting the entire message multiple times. Even if some packets are lost, the receiver could reconstruct the message from redundant copies. While this *works*, it’s terribly inefficient, the bandwidth overhead is enormous.

We want high reliability without excessive redundancy. A connection-oriented protocol like TCP seems like the next logical choice: the sender retransmits only the packets that weren’t acknowledged. This improves bandwidth efficiency, but at the cost of *latency*, every lost packet requires a round-trip before recovery. For many time-sensitive systems, that back-and-forth simply isn’t acceptable. In some applications, it’s better to drop packets than to stall. But what if reliability *is* essential? Can we transmit data with high reliability and low latency, avoiding retransmissions altogether?

## The promise of erasure codes

If we can estimate the percentage of packets likely to be lost during transmission, say, due to noise, congestion, or interference we can use **erasure coding** for reliable, one-way transmission. In coding theory, an erasure code is a type of *forward error correction* (FEC) code. FEC schemes allow the receiver to detect and correct errors, or, in the case of erasures, to reconstruct missing data, without requiring retransmission. This property is invaluable for storing data across unreliable networks or transmitting it through noisy channels. For example, if a sender transmits several data packets to a receiver, the goal of an erasure code is to enable the receiver to reconstruct the original message even if some packets are lost in transit (i.e., "erased").

Erasure codes work by transforming an original message of $n$ symbols into a longer message of $m$ symbols. The $n$ original symbols are called *source symbols*, while the $m$ transformed $ones are *encoded symbols*. Even if some encoded symbols are lost, the receiver can reconstruct the original message using a subset of the $m$ encoded symbols. The number of encoded symbols required to recover the original message depends on the erasure code's *code rate*, defined as $\frac{n}{m}$. Or in other words, it represents the portion of the data that is not redundant. An *optimal erasure code* allows full reconstruction from any $n$ of the $m$ encoded symbols. I’m intentionally reusing the symbol $m$ here. Previously it referred to the Bloom filter size; now I use it for the number of encoded symbols. That’s not an accident: in our scheme, the filter is the encoding, so its bits are the encoded symbols.


## Designing a Bloom filter–based erasure encoder

Now imagine applying this logic to network packets. If we could transform $n$ packets into $z$ packets (where $z > n$) and transmit them using a connectionless protocol, the receiver could reconstruct the original data from any subset of those $z$ packets, even if some were lost along the way. Here’s where Information Chaining re-enters the picture. Our Bloom filter–based prototype can be adapted into an erasure code in multiple ways:

- Use many small Bloom filters (with higher false positive rates) and compress them, for instance, using [Golomb Coded Sets](https://web.archive.org/web/20220620080435/https://giovanni.bajo.it/post/47119962313/golomb-coded-sets-smaller-than-bloom-filters). Or
- Use a single large Bloom filter and later packetize it.

To keep things simple, let’s explore the second option.

Suppose we expect 10% packet loss during transmission. That means our *loss rate* $l$ is $0.1$. We take our input message of $n$ bits, encode it into a single large filter of $m$ bits, split that filter into packets, and ship them out. The receiver reconstructs the filter from whatever packets arrive. Any missing packet region is treated as “unknown” and is set to 1 in the filter. That last choice is the entire crux. Packet loss increases the probability that a lookup lands in a region that we blindly declare present. In this section, we’ll derive the correct sizing formula under one explicit assumption:

> **Assumption:** we are using the Part 1 *simplified* filter variant with **$k = 1$**, meaning each insertion sets exactly one bit.


With $k = 1$, each inserted element maps to one bit position. Because of collisions, inserting $n$ elements does not set $n$ distinct bit positions. The question becomes: after $n$ random insertions into $m$ bits, what fraction of bits are expected to be 1? Pick a specific bit in the filter. The probability that a single insertion does not hit it is:
$\left(1 - \frac{1}{m}\right)$. So the probability that none of the $n$ insertions hit it is: $\left(1-\frac{1}{m}\right)^n$. Therefore, the probability that this bit ends up being 1 (i.e., it got hit at least once) is: $p_0 = 1 - \left(1-\frac{1}{m}\right)^n$. For our $k=1$ filter, this is also the *baseline false positive rate*. For large $m$, we use the classic approximation:
$$
\left(1-\frac{1}{m}\right)^n \approx e^{\frac{-n}{m}}
\quad\Rightarrow\quad
p_0 \approx 1 - e^{\frac{-n}{m}}
$$


If packets are all the same size, then losing a fraction $l$ of packets means losing roughly a fraction $l$ of the filter’s bits. Recall, in this implementation, lost bits are set to 1. So for a wrong-path lookup (a non-member query), there are two cases:

- With probability $l$, the lookup lands in a missing region, where the bit is forced to 1, which returns a positive match. It can be a true positive, but it also might be a false positive.
- With probability $1-l$, the lookup lands in a received region, where the baseline false positive rate is $p_0$.

So the *effective* false positive rate seen by the decoder is: $\left(p_{\text{eff}} = l + (1-l)p_0\right)$. This equation is the bridge between *packet loss* and *decoder branching*. Loss shows up exactly where it hurts: in the probability that the decoder is forced to say “maybe”. In the rest of this post, the false positive rate $p$ is what governs branching behavior during decoding. In the erasure setting, that “$p$” should really be $p_{\text{eff}}$, the rate after erasures have done their damage.

So we pick a target $p_{\text{eff}}$ (for example, $0.48$ to keep branching under control), and we solve for the baseline rate we must achieve *before* packet loss: $\left(p_0 = \frac{p_{\text{eff}} - l}{1-l}\right)$. Now we plug $p_0$ into the collision/occupancy equation: $\left(1 - \left(1-\frac{1}{m}\right)^n = \frac{p_{\text{eff}} - l}{1-l}\right)$. After rearrangement: $\left(\left(1-\frac{1}{m}\right)^n = \frac{1 - p_{\text{eff}}}{1-l}\right)$. Then we take the $n$th root and get: $\left(1-\frac{1}{m} = \left(\frac{1 - p_{\text{eff}}}{1-l}\right)^{\frac{1}{n}}\right)$. And finally we solve for $m$:

$$
m = \frac{1}{1 - \left(\frac{1 - p_{\text{eff}}}{1-l}\right)^{\frac{1}{n}}}
$$

That’s the exact, collision-aware sizing rule for the $k=1$ erasure encoder. For large $n$ (and this is typically the regime we care about), we can use the exponential approximation and get a much nicer closed form:

$$
m \approx -\frac{n}{\ln\left(\frac{1 - p_{\text{eff}}}{1-l}\right)}
$$


In simpler terms, *Code Example 4* takes as input the message length $n$ (in bits), the expected packet loss rate $l$, the target effective false positive rate $p_{\text{eff}}$ (e.g., $0.48$), and the packet payload size in bytes. the function then Computes $m$ using the formula above (exact or approximate), round $m$ up to a byte boundary, then round again to a whole number of packets, and finally run the same chained insertion loop as in *Code Example 2* (we still insert exactly $n$ chain headers), and then packetize the resulting bit array. That’s it. Erasure are automatically accounted for by the filter expansion (larger $m$).

{{< readfile file="code_examples/zig/information_chaining_part_1/src/erasure_encoder.zig" lang="zig" title="Code Example 4. Bloom Filter Erasure Encoder">}}

## Decoding with erasures

Once the receiver collects the packets, it reconstructs the original Bloom filter from the chunks. Any regions corresponding to missing packets are treated as “unknown” and are set to `1`s. A lookup that lands in a missing region becomes therefore an unconditional match. During decoding, this means that whenever we reach a missing portion of the filter, we must treat *both* continuations as viable candidates, effectively branching off from every path currently stored in memory (see Figure 8). As long as the actual packet loss rate stays at or below the target loss rate used during encoding, the decoder can still recover the original message. And just like that, we’ve created a **Bloom filter–based erasure code**!

<p align="center">
 <img width="100%" height="100%" src="/images/information_chaining_part_1/decoding_with_erasures.svg">
 <em><br/>Figure 8. Decoding with missing packets causes branch-offs, enabling recovery despite erasures.</em>
</p>

For the hands-on reader, *Code Example 5* shows the corresponding decoder implementation. Feel free to experiment with different loss rates and false positive parameters to internalize the dynamics. Decreasing the target false positive rate for a fixed loss rate reduces the decoder’s memory footprint (fewer branches survive), but increases bandwidth (the code overhead grows). As the target false positive rate approaches $0.5$, the overhead drops, but the number of potential paths rapidly increases.

{{< readfile file="code_examples/zig/information_chaining_part_1/src/erasure_decoder.zig" lang="zig" title="Code Example 5. Bloom Filter Erasure Decoder">}}


## The role of the chain header

Earlier, we noted that the chain header bit size directly affects Information Chaining performance.  
You might now ask: “Why use a multi-bit chain header at all? Couldn’t we just make random changes to a single bit instead?”Surprisingly, the answer is **no**, and the reason is subtle. Think of the chain header as an **identifier** for a path within the decoding tree. If two candidate paths (say, the correct path and a wrong path) ever share the same chain header at the same depth, they will evolve identically from that point onward, meaning the wrong path can *never* be pruned. In other words, the chain header must carry enough information to uniquely distinguish all candidate paths that might exist at a given depth. If you expect only a few candidates per iteration, a small header suffices. But if you expect many candidates, for instance, when aiming for minimal space overhead at a given loss rate, you’ll need a larger, more information-rich chain header. This dynamic might seem obvious in hindsight, but it elegantly ties together randomness, redundancy, and recoverability.

# Reflection and teasers

While neat in concept, the erasure code I presented has several clear shortcomings.


The first issue is **bandwidth overhead**. With regular Bloom filters and a false positive rate of, say, $0.49$, we’d need to transmit roughly 1.76× as many bits as in the original message just to tolerate a 10% packet loss rate. While better than retransmission, that’s still a steep cost for an erasure code. Using [Golomb Coded Sets](https://web.archive.org/web/20220620080435/https://giovanni.bajo.it/post/47119962313/golomb-coded-sets-smaller-than-bloom-filters) brings the overhead down somewhat, and combining Bloom filter–based Information Chaining with a peeling algorithm can reduce it even further (while increasing decoding time). But even those numbers still fall short compared to state-of-the-art erasure codes used in modern streaming systems.

The second issue lies in **memory and latency performance**. Even with heavy optimization such as SIMD, Bloom filter–based Information Chaining involves a lot of random memory access, leading to frequent cache misses. And perhaps more problematic, its probabilistic nature causes branch formation during decoding even when no erasures are present. While wrong branches are pruned quickly, ideally they shouldn’t appear at all unless data is actually missing.

Although these critiques sound harsh, the core idea of Information Chaining still holds remarkable promise. Good engineering isn’t just about dismantling ideas quickly, it’s about recognizing the *fragments of potential* within them. When I first conceived of Information Chaining more than a year ago, I had little more than a gut feeling that there was something special about it. Since then, through countless iterations and prototypes, we’ve developed versions that not only surpass traditional approaches like RaptorQ codes (we’ll explore Raptor codes in upcoming posts), but do so on an entirely new performance frontier.

Going forward, I plan to maintain this tinkering-driven approach throughout the series. The goal isn’t to unveil the final, polished version of Information Chaining right away, but to guide you, the reader, through the same process of exploration we went through. By the end, I want you to feel like you’ve arrived at the concept yourself.

In this first post, we planted the seed: the foundational idea of Information Chaining. Part Two will introduce the next stage, a more efficient, probabilistic Information Chaining variant that reduces bandwidth overhead and eliminates the need for approximate membership query filters like Bloom filters. Part Three will unveil collision-free Information Chaining, a version that forms decoding branches only in the presence of erasures, dramatically improving both memory efficiency and latency. We’ll also introduce the benefits of fountain codes in this context. Part Four will cover Rapid Information Chaining, the FPGA/ASIC-friendly incarnation with stunning speed, minimal memory footprint, and an exceptional overhead-to-loss ratio. Finally, Part Five will explore Gaussian-based Information Chaining, a non-probabilistic Information Chaining variant, that achieves more favorable computational complexity in regimes where erasures are frequent or extensive.

---

# How to Cite This Work

If you enjoyed this post, consider sharing it with others who might find it valuable, knowledge grows when shared. Curious about our work or interested in collaborating? [Drop me a line](mailto:lum@opencybernetics.io). I'm always eager to connect with like-minded innovators.

If you’d like to reference this article in your own research or writing, please cite it as follows:

> **Lum Ramabaja (2026).** *Let It Bloom: The Seeds of Information Chaining (Part 1).*  
> Open Cybernetics Blog. [https://lumramabaja.com/posts/let-it-bloom-the-seeds-of-information-chaining-part-1/](https://lumramabaja.com/posts/let-it-bloom-the-seeds-of-information-chaining-part-1/)

You can also cite it in **BibTeX** format:

{{< highlight bibtex >}}
@article{ramabaja2026informationchaining1,
  title   = {Let It Bloom: The Seeds of Information Chaining (Part 1)},
  author  = {Ramabaja, Lum},
  year    = {2026},
  journal = {Open Cybernetics Blog},
  url     = {https://lumramabaja.com/posts/let-it-bloom-the-seeds-of-information-chaining-part-1/}
}
{{< /highlight >}}

