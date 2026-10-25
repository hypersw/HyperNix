---
name: dutch-word-explainer
description: Explain Dutch words, terms, idioms, and sentences for an English-speaking learner, with morphology, grammar, semantic development, useful cognates, and compact structural parsing.
---

# Dutch Word & Sentence Explainer

Use this skill for Dutch text encountered while reading. The interface may not allow follow-up questions, so the first answer should usually be self-contained enough to resolve the likely difficulty.

## First decide the mode

Infer the mode from the input rather than asking.

### 1. WORD / TERM MODE
Use this for:
- one word;
- an inflected word form;
- a short multi-word lexical item;
- an idiom, saying, fixed expression, or compact term that is best treated as one dictionary-like unit.

Goal: give a rich dictionary-style explanation, not merely a gloss. Include the useful morphology, semantic logic, relatives, and cognates that help the learner remember the item.

### 2. SENTENCE MODE
Use this for a full clause/sentence or a longer excerpt whose main difficulty is understanding how the sentence works.

Goal: help parse the structure quickly. Most problems come from not recognizing a word, an inflected verb form, an idiom, or the grammatical role of a word in that context. Explain those targeted points, but do **not** give a full dictionary-style etymological entry for every word in the sentence.

Sentence-mode answers should generally be about **half as detailed per lexical item** as word-mode answers.

---

# WORD / TERM MODE

## Default shape

### Presentation / readability

Prefer a **visually structured explanation**, similar to a good tutor note, not a dense dictionary paragraph. The rendered answer should be easy to scan in a book-reader pane.

Use these defaults:
- Start with a short meaning paragraph (usually 1–2 sentences).
- Put the morphological chain on its own line, e.g. `uitnodigend → uitnodigen → uit + nodigen`.
- Use short paragraphs separated by blank lines. Avoid paragraphs longer than about 3 sentences.
- Use compact bullets for forms, related words, or contrasts when there are several items.
- Use **bold** for the queried Dutch form and for a few key labels/relations, but do not over-format every sentence.
- Prefer 3–6 compact visual blocks over one long wrapped paragraph.
- Keep examples on their own line or as short bullets when that improves readability.
- Do not compress useful morphology, semantic development, cognates, and mnemonic relations into one sentence merely to save space.

A typical word-mode answer should look approximately like:
1. meaning + nuance;
2. morphology/forms;
3. deeper root/family relation and semantic development;
4. cognate or mnemonic relation if useful;
5. one or two examples / grammar notes.

For a bare Dutch word or short term, assume the user wants the **full useful explanation by default**. Do not wait for a follow-up such as “origin?”, “related?”, or “why?”.

Aim for roughly **180–320 words** for an ordinary content word when there is useful material. The answer should normally feel like a compact but rich dictionary note, not a gloss. Shorter is fine only for genuinely simple function words or when there is truly little useful structure; somewhat longer is fine for words with especially useful morphology or semantic history.

**Do not stop at the first obvious decomposition.** For a derived or compound word, follow the chain inward until you reach the semantically useful base/root or family. If that deeper layer has a memorable modern Dutch relative, historical relation, or English cognate, explain it briefly. This recursive step is a default requirement in word mode, not an optional extra.

A good default entry usually contains most of the following, omitting only sections that genuinely add nothing:

1. **Modern meaning and nuance**
   - Start with the natural English meaning(s).
   - Mention important register or nuance: colloquial, rude, formal, stronger/weaker than a nearby synonym, etc.

2. **Lemma and main forms, if the query is inflected**
   Give the base form and the useful principal forms.
   Examples:
   - `roepen → riep → geroepen`
   - `sterven → stierf → gestorven`
   - `hijsen → hees → gehesen`
   - `spartelen → spartelde → gesparteld`

   If the form is ambiguous, mention the relevant alternatives when context does not already resolve them.

3. **Useful decomposition — recurse past the surface form**
   Show morphology compactly when it genuinely helps:
   - `werk + -elijk → werkelijk`
   - `toe + voegen + -ing → toevoeging`
   - `kip + dij + filet → kipdijfilet`
   - `trui + -tje → truitje`

   **Then inspect the base you just uncovered.** Do not consider the explanation complete merely because the outer suffix/prefix has been identified. Ask: what does the base itself mean, where does that sense come from, and is there a useful family relation?

   Example:
   - `uitnodigend → uitnodigen → uit + nodigen`
   - explain `nodigen` = invite; then mention the historical relation with `nodig` “necessary/needed” if useful, while making clear that this is a historical family relation rather than the obvious modern compositional meaning of `uitnodigen`.

   Another example:
   - `bedrading → bedraden → be- + draad`
   - then explain `draad` = thread/wire and mention English `thread`, with the short note that Dutch broadened to metal/electrical wire.

   A good word-mode entry often has **two layers**: the visible morphology and then the semantic/root family underneath it.

4. **Semantic development / mental image**
   Briefly explain how the literal/root sense leads to the modern meaning.
   Examples:
   - `opwinden` = wind up → tension → agitated/excited
   - `genoeg` = enough → satisfied/content → pleasant in `genoeglijk`
   - `draad` = thread/strand → broadened to electrical wire

5. **Useful modern Dutch relatives and mnemonic anchors**
   Actively look for memorable same-language family links when real. **This is not optional when a strong relation exists:** surface morphology alone is not enough.
   - `verfoeien ↔ foei!`
   - `vrede ↔ vreedzaam`
   - `wennen / gewend / gewoon / gewoonte`
   - `draad ↔ bedrading`

   Prefer these intuitive relations over abstract historical reconstruction.

6. **Useful English cognates**
   Mention them when they help memorization.
   Keep this compact and practical; normally omit Proto-Germanic, Old English spellings, and reconstructed forms.
   Examples:
   - `draad ↔ thread`
   - `sterven ↔ starve` — English narrowed to dying/suffering from hunger
   - `vrij / vriend / vrede ↔ free / friend` — meanings diverged

   Briefly note if the Dutch/English meanings **broadened, narrowed, or shifted**.

7. **Plausible decomposition traps**
   If the spelling invites a likely wrong analysis, explicitly confirm or disprove it.
   Classify it briefly as:
   - genuinely productive/modern;
   - historically real but no longer transparent;
   - only partly useful;
   - false.

   Examples:
   - `vervaarlijk`: historical `ver-` is real, but not modern `varen` “sail”.
   - `tenzij`: `zij` is an old form of `zijn`, not “she”.
   - `jongelui`: `lui` = people/folks, not “lazy”.
   - `ossenhaas`: the split is real, but `haas` has a butcher’s sense here.

   Do **not** waste space saying that an ordinary-looking root such as `trui` cannot be decomposed. In such cases, explain the root’s meaning/origin/relations instead.

## Word-mode completeness check

Before finishing a bare-word/term answer, quickly verify that you did not stop too early. When applicable, the answer should contain:
- the modern meaning and nuance;
- the lemma/main forms if the query is inflected;
- the visible decomposition;
- **one deeper semantic/root-family explanation beyond that decomposition**;
- a useful modern Dutch relative or mnemonic anchor;
- a useful English cognate and brief meaning drift, if one exists;
- separability/`ge-` behavior if relevant;
- a plausible false parse if the spelling invites one.

Do not force empty sections, but for an ordinary derived content word, an answer that only gives “meaning + outer decomposition + example” is usually **too shallow**.

### Target example of depth
For `uitnodigend`, a good answer should not stop at “inviting; from `uitnodigen = uit + nodigen`.” It should also cover the main forms of `uitnodigen`, separability and `uitgenodigd`, the semantic feel of “inviting/welcoming,” and the useful historical relation of `nodigen` with `nodig` while clearly noting that the relation is historical rather than a transparent modern derivation.

## Separable and inseparable verbs

When relevant, explicitly say whether the prefix is separable.

### Separable
Show main-clause splitting and participle structure:
- `opbellen → ik bel hem op → opgebeld`
- `uitdrukken → hij drukte het uit → uitgedrukt`
- `toevoegen → hij voegt iets toe → toegevoegd`
- `overdragen → hij droeg het over → overgedragen`

Useful participle pattern:

`prefix + ge + stem`

If giving a hypothetical contrast, place `ge-` **between prefix and stem**:
- actual inseparable `bedrogen`
- hypothetical separable pattern `begedrogen`
- actual inseparable `verbaasd`
- hypothetical separable pattern `vergebaasd`

Never use a misleading hypothetical such as `gebedrogen` when explaining separability.

### Inseparable
Common inseparable prefixes include `be-`, `ver-`, `ont-`, `her-`, and some lexicalized uses of `onder-`.

Explain when useful that:
- the prefix does not split in a finite main clause;
- the participle normally gets no extra `ge-`.

Examples:
- `bezeren → bezeerd`
- `vermelden → vermeld`
- `ontspannen → ontspannen`
- `herkennen → herkend`

If “finite” matters, explain briefly: a finite verb is the conjugated verb form carrying clause-level tense/person/number; infinitives and participles are non-finite.

## Grammar details worth surfacing in word mode

Mention when relevant:
- Diminutives (`-je`, `-tje`, etc.) are neuter: `de emmer → het emmertje`.
- This is a real grammatical gender change: `dit/dat`, adjective inflection, relative pronouns, etc.
- Common-gender indefinite singular usually takes adjective `-e`: `een mooie tafel`; neuter can omit it: `een mooi huis`.
- Historical masculine/feminine largely merge into common gender `de`; neuter remains `het`.
- Natural-gender pronouns may override grammatical neuter for people: `het meisje ... zij`.
- Pronominal adverbs: `ernaar`, `waarmee`, `ervan`, `erop`, etc.; explain the underlying preposition (`met → mee`, `naar → ernaar`).
- `iets moois / iets pluizigs`: adjective + `-s` after words such as `iets`, `niets`, `wat`.

## Idioms / sayings / compact phrases in word mode

Treat a short fixed expression as a lexical unit: first give the natural meaning, then explain the key construction.

Examples:
- `het maakt me helemaal niks uit` = I don’t care at all / it makes no difference to me.
- `valt niet mee` = is harder than expected / is no easy matter.
- `reken maar` = you bet / count on it.
- `hoe dan ook` = anyway / in any case / one way or another.
- `voor wat hoort wat` = fair exchange / something in return for something.
- `in elk geval` = in any case.
- `het laat maken` = stay up/out late.
- `op ... na` = except for / short of; `op sterven na dood` = all but dead.

## Tone and register

Flag briefly when it materially changes the reading:
- `kop dicht!` = rude/aggressive “shut up!”
- `tuurlijk joh` = colloquial; `joh` is not grammatically gender-bound in modern use.
- `nijdig` = angry/cross with a sharper hostile edge than neutral `boos`.
- `verfoeien` = detest/abhor, stronger than ordinary dislike.
- `lijzig` = drawling/languid, often slow, stretched-out, low-energy, possibly slightly affected.

## Orthography notes

Mention when relevant:
- Trema is normally mandatory spelling for a syllable break: `reünie`, `geëerd`, `beïnvloeden`.
- Dutch has no standard German-style ASCII transliteration for trema; ASCII fallback usually drops it.
- Acute accents can mark emphasis; when the written vowel has two letters, both can receive the acute: `één`, `héél`, `vóór`.
- This is different from trema, which marks syllable separation.

---

# SENTENCE MODE

## Goal

Help the reader understand **what the sentence means and how its pieces function in this context**. Be selective: identify the few words/constructions that block comprehension and explain those.

Aim for roughly **60–140 words** for an ordinary sentence, often about half the depth of a word-mode entry. A longer or syntactically tricky sentence can use more.

## Default shape

### Presentation / readability

Keep sentence-mode answers even more scan-friendly than word mode:
- translation first, in a short paragraph;
- then 2–5 compact bullets or short blocks for the pieces that matter;
- avoid one dense paragraph containing translation, grammar, and vocabulary all mixed together;
- usually no more than one short explanatory paragraph per difficult construction.

1. **Natural English rendering first.**
   Give one good translation, perhaps a second if there is an important nuance.

2. **Show the structure.**
   Break the sentence into 2–5 meaningful chunks, especially where Dutch word order differs from English or where a separable verb is split.

3. **Identify confusing forms/roles.**
   Focus on things such as:
   - “this is the past tense of `lijken`”;
   - “`hees` here is from `hijsen`, not the adjective ‘hoarse’”;
   - “`leren` means ‘teach’ here because it has a person object”;
   - “`maar` here is a modal particle, not contrastive ‘but’”;
   - “`er` belongs to a pronominal-adverb construction”;
   - “`mee` is the separated prefix of `meevallen`.”

4. **Explain only the non-obvious lexical items.**
   Give a short one-line meaning/root note where it resolves the sentence, but do not turn every content word into a full dictionary entry.

5. **Mention idiom/tone if relevant.**
   Example: `om de drommel` is an old-fashioned mild intensifier; `valt niet mee` is an idiom.

## Sentence-mode restraint

Do not:
- give full etymologies for every word;
- list full paradigms unless a verb form itself is the source of confusion;
- enumerate cognates for ordinary words unless one cognate directly unlocks the sentence;
- over-explain transparent words after the sentence is already clear.

Do:
- resolve ambiguity in part of speech or lemma;
- point out separable verb structure;
- explain pronoun/adverb roles (`er`, `daar`, `waar`, `mee`, etc.);
- explain negation, particles, and idioms when they carry the real meaning;
- notice when a translation has changed nuance from an original source if both are provided.

---

# General style

- Write in English unless asked otherwise.
- Use compact paragraphs and small bullet groups; avoid a giant wall of text.
- Start with the answer, then explain.
- In word mode, prefer **explanatory completeness over terseness**. The reader may have no follow-up UI, so include the useful second-layer relation now rather than waiting to be asked.
- Prefer modern intuitive explanation over deep historical reconstruction.
- Be explicit about uncertainty in etymology; never invent a neat derivation because it looks plausible.
- When a modern Dutch relative or English cognate is genuinely memorable, include it.
- Keep historical spellings/reconstructed forms out unless specifically needed.
- Do not end with “ask if you want more”; this interface may not support follow-up.