# Answer quality with and without regex, 2026-11-06

Invented transcripts, normal tier on Claude. Ratings are blind, by the frontier tier: accuracy/usefulness out of 5, with regex vs without. Small sample, so read this as direction, not proof.

| Transcript | Facts, with regex | Facts, without | Formatted values sent | Tokens not restored | Rating |
|---|---|---|---|---|---|
| base-meeting | 8/8 | 8/8 | 0 | 0 | 5/5 vs 4/3 |
| base-therapy | 8/8 | 8/8 | 0 | 0 | 4/5 vs 4/4 |
| base-mixed | 3/3 | 3/3 | 0 | 0 | 4/3 vs 5/4 |
| ind-01 | 4/5 | 4/5 | 0 | 0 | 5/5 vs 4/3 |
| ind-02 | 5/5 | 5/5 | 0 | 0 | 3/4 vs 4/4 |
| ind-03 | 5/5 | 4/5 | 0 | 0 | 4/5 vs 5/4 |
| ind-04 | 5/5 | 5/5 | 0 | 0 | 4/5 vs 3/3 |
| ind-05 | 4/5 | 4/5 | 0 | 0 | 5/5 vs 5/4 |
| ind-06 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 4/5 |
| ind-07 | 5/5 | 5/5 | 0 | 0 | 2/3 vs 4/4 |
| ind-08 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 4/4 |
| ind-09 | 5/5 | 5/5 | 0 | 0 | 4/5 vs 4/3 |
| ind-10 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 4/4 |
| ind-11 | 5/5 | 5/5 | 1 | 0 | 4/3 vs 3/4 |
| ind-12 | 4/5 | 4/5 | 0 | 0 | 4/5 vs 4/3 |
| ind-13 | 5/5 | 5/5 | 0 | 0 | 5/4 vs 4/4 |
| ind-14 | 5/5 | 5/5 | 0 | 0 | 3/3 vs 4/4 |
| ind-15 | 5/5 | 5/5 | 0 | 0 | 3/4 vs 4/4 |

**Totals:** facts 91/94 with regex, 90/94 without; 1 formatted values sent with regex; 0 tokens not restored.

**Mean rating over 18:** with regex 4.11 accuracy, 4.22 usefulness; without 4.06, 3.78.

**Losses:** none.

## Follow-up on ind-07
The with-regex answer was rated lower here (2/3 vs 4/4). The rater's note wasn't saved, so the reason is unknown. One repeat was read by hand, and it was accurate with every token restored. The next run should save the rater's notes.

The one formatted value sent in ind-11 is a bare nine-digit SSN, a documented limit (`testBareNineDigitSSNIsADocumentedMiss`).
