# Answer quality with and without regex, 2026-11-06

Invented transcripts, normal tier on Codex. Ratings are blind, by the frontier tier: accuracy/usefulness out of 5, with regex vs without. Small sample, so read this as direction, not proof.

| Transcript | Facts, with regex | Facts, without | Formatted values sent | Tokens not restored | Rating |
|---|---|---|---|---|---|
| base-meeting | 8/8 | 8/8 | 0 | 0 | 5/5 vs 5/4 |
| base-therapy | 8/8 | 8/8 | 0 | 0 | 5/5 vs 4/5 |
| base-mixed | 3/3 | 3/3 | 0 | 0 | 5/4 vs 5/5 |
| ind-01 | 4/5 | 5/5 | 0 | 0 | 5/4 vs 5/4 |
| ind-02 | 5/5 | 5/5 | 0 | 0 | 5/5 vs 5/5 |
| ind-03 | 5/5 | 4/5 | 0 | 0 | 5/4 vs 5/4 |
| ind-04 | 4/5 | 4/5 | 0 | 0 | 5/4 vs 5/4 |
| ind-05 | 4/5 | 4/5 | 0 | 0 | 5/5 vs 5/4 |
| ind-06 | 5/5 | 5/5 | 0 | 0 | 5/5 vs 5/5 |
| ind-07 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 5/4 |
| ind-08 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 5/5 |
| ind-09 | 5/5 | 5/5 | 0 | 0 | 5/5 vs 5/4 |
| ind-10 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 5/5 |
| ind-11 | 5/5 | 5/5 | 1 | 0 | 5/4 vs 5/4 |
| ind-12 | 4/5 | 4/5 | 0 | 0 | 4/4 vs 5/3 |
| ind-13 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 4/4 |
| ind-14 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 5/4 |
| ind-15 | 5/5 | 5/5 | 0 | 0 | 5/5 vs 5/5 |

**Totals:** facts 90/94 with regex, 90/94 without; 1 formatted values sent with regex; 0 tokens not restored.

**Mean rating over 18:** with regex 4.94 accuracy, 4.39 usefulness; without 4.89, 4.33.

**Problems:**
- ind-01: with regex lost october 14

## Follow-up on the ind-01 loss
Not a lost fact: a scoring error. Repeated 3 times each, Codex with regex wrote `2026-10-14` every time and without regex wrote `October 14, 2026` every time, so the date is in all 6 answers. The fixture's fact accepted only month-name forms, so the ISO form scored as missing. `2026-10-14` is now an accepted form. This table wasn't re-run, so it still shows the old count: with that fix it would read 91/94 with regex, 90/94 without.

The repeat does show a consistent style difference on this transcript: with regex, Codex copied the date and the amount (`$48,000.00`) as written rather than rewording them. Three runs on one transcript isn't enough to generalize.
