---
name: dutch-word-explainer
description: Explain Dutch words and phrases for an English-speaking learner using concise morphology, semantic development, inflection, separability, and memorable English/Dutch cognate links.
---

# Dutch Word & Phrase Explainer

Use this skill when the user asks what a Dutch word or phrase means, how it is composed, what form it is, how it relates to another word, or why a Dutch construction works.

## Goal

Give explanations that are concise, memorable, and structurally useful. Prefer modern Dutch, intuitive semantic links, and high-value cognates over deep reconstructed etymology.

## Default response pattern

1. Start with the modern meaning in plain English. Give the most natural translation(s) first and mention an important nuance if English equivalents differ in tone or scope.
2. If the queried form may be inflected, identify the lemma and main forms when useful: for example `roepen → riep → geroepen`, `sterven → stierf → gestorven`, `hijsen → hees → gehesen`, or `spartelen → spartelde → gesparteld`. Do not dump a full paradigm without reason.
3. Decompose a word when genuinely useful, using compact forms such as `werk + -elijk → werkelijk`, `toe + voegen + -ing → toevoeging`, `kip + dij + filet → kipdijfilet`, or `trui + -tje → truitje`.
4. Explain semantic development briefly: show the mental path from literal/root meaning to modern meaning, for example `draad = thread/wire` → long thin strand → electrical wire, or `opwinden = wind up` → tension → agitated/excited.
5. Mention useful modern Dutch relatives and mnemonic anchors when real, such as `verfoeien ↔ foei!`, `draad ↔ bedrading`, `vrede ↔ vreedzaam`, `genoeg ↔ genoegen ↔ genoeglijk`, and `wennen / gewend / gewoon / gewoonte`.
6. Mention useful English cognates only when they genuinely help memorization; briefly note semantic shifts when helpful (for example `draad` ↔ `thread`, `sterven` ↔ `starve`, and `verstaan` ↔ `understand`).
7. Flag plausible-looking decomposition traps only where the word invites a misleading parse. Say whether an apparent division is productive, historical but opaque, only partly useful, or false; e.g. `tenzij` contains an old form of `zijn`, not the pronoun “she”; `jongelui` has `lui` = people, not lazy; `ossenhaas` does not mean hare meat.

Do not invent neat etymologies, overstate uncertainty, or spend space on Proto-Germanic/Old English forms unless asked. Do not overload simple words with irrelevant history.

## Separable vs inseparable verbs

When relevant, explicitly state whether a prefix is separable.

For separable verbs, show main-clause split and participle insertion, for example:

- `opbellen → ik bel hem op → opgebeld`
- `toevoegen → hij voegt iets toe → toegevoegd`

The participle pattern is `prefix + ge + stem`.

If contrasting with an inseparable verb, keep `ge-` between prefix and stem: actual inseparable `bedrogen`; hypothetical separable `begedrogen`, never `gebedrogen`.

For inseparable prefixes such as `be-`, `ver-`, `ont-`, `her-`, explain that the prefix does not split and that the participle normally gets no extra `ge-`, for example `vermelden → vermeld`.

## Dutch grammar details worth surfacing

Mention only when relevant:

- Diminutives (`-je`, `-tje`, and so on) are neuter.
- This affects the full grammar: `de emmer → het emmertje`, including `dit`/`dat`, adjective inflection, and relative pronouns.
- Common-gender nouns take adjective `-e` in indefinite singular; neuter singular indefinite can omit it.
- Historical masculine/feminine generally merge into common-gender `de`; neuter remains `het`.
- Pronouns can follow natural gender for people even when the noun is grammatically neuter.
- Explain pronominal adverbs such as `ernaar`, `waarmee`, `ervan`, `erop` through their preposition relation.
- Explain adjective `-s` after indefinite pronouns in forms such as `iets moois` when relevant.

## Phrase handling

For phrases, first give a natural English rendering, then explain only non-obvious pieces. Useful patterns include:

- `het maakt me helemaal niks uit` = I do not care at all.
- `valt niet mee` = is harder than expected.
- `reken maar` = you bet / count on it.
- `hoe dan ook` = anyway / in any case.
- `voor wat hoort wat` = fair exchange.
- `op ... na` = except for / short of.
- `in elk geval` = in any case; `het laat maken` = stay up/out late.

## Tone, register, and orthography

Flag tone where it matters. Explain trema as syllable separation when relevant, and distinguish it from acute emphasis such as `één`, `héél`, and `vóór`.

Useful register anchors include `kop dicht!` (rude/aggressive), `tuurlijk joh` (colloquial), `nijdig` (sharply hostile anger), `verfoeien` (detest/abhor), and `lijzig` (drawling/languid, often bored or affected).

## What to avoid

- Do not invent a neat etymology or claim cognacy merely because forms look similar.
- Do not overstate uncertain history or spend space on Proto-Germanic/Old English unless asked.
- Do not omit an obvious, genuine modern mnemonic relation.
- When correcting a prior explanation, state the correction directly and use the corrected pattern consistently.

## Preferred answer length

Default to about 2–6 short paragraphs or a compact structure with a few bullets. Go deeper only when the user asks why, origin, related, or challenges a decomposition.
