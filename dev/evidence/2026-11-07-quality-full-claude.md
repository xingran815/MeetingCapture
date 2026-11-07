# Report quality with and without regex, full pipeline, 2026-11-07

Invented transcripts, one per scenario, on Claude: classify, sections, concepts and frontier review, run with regex and without. Each cell is with regex / without. Section ratings are blind, by the frontier tier, 1 to 5. Small sample, so read this as direction, not proof.

| Transcript | Expected | Scenario | Topic | Sections filled | Facts kept | Tokens restored | Unsure items | Reviewed |
|---|---|---|---|---|---|---|---|---|
| scenario-general | general | general / general | differs | 5/5 / 5/5 | 7/7 of 7 | yes | 3 / 4 | both |
| scenario-interview | interview | interview / interview | differs | 6/6 / 6/6 | 7/7 of 7 | yes | 0 / 2 | both |
| scenario-lecture | lecture | lecture / lecture | differs | 5/5 / 5/5 | 7/6 of 7 | yes | 1 / 1 | both |
| scenario-meeting | meeting | meeting / meeting | same | 5/5 / 5/5 | 7/7 of 7 | yes | 4 / 3 | both |
| scenario-one_on_one | one_on_one | one_on_one / one_on_one | same | 6/6 / 6/6 | 7/7 of 7 | yes | 1 / 1 | both |
| scenario-therapy | therapy | therapy / therapy | differs | 7/7 / 7/7 | 7/7 of 7 | yes | 2 / 1 | both |

## Section ratings

| Transcript | Section | With regex | Without | Rater's note |
|---|---|---|---|---|
| scenario-general | summary | 4 | 5 | Both are accurate. A is more useful because it gives the owners and timing: Speaker 1 confirms the keys tonight and looks up whether the museum opens on Sunday, and the Saturday queue is the reason. It also gives the confirmation email address. B is correct but vaguer. It lists topics without saying who does what, and 'send the booking confirmation to the group' loses the specific address. |
| scenario-general | who_said_what | 4 | 5 | A follows the transcript turn by turn. It includes You asking about the keys, Speaker 1's 'Yes' agreeing to confirm tonight, the owner's number exactly as spoken, and You's 'Will do'. B is accurate but leaves things out. It drops You raising the keys question and Speaker 1 agreeing to confirm, says only 'Shared the owner's number' without giving it, and drops You agreeing to send the confirmation. |
| scenario-general | open_questions | 4 | 5 | Both correctly list the museum Sunday hours, the keys and the discount card as unresolved. A's discount-card answer ('possibly Maria's, unconfirmed') reflects the transcript better than B's flat 'I don't know'. A also adds the postponed packing list, which is a fair open item with no owner. B is accurate but less complete. |
| scenario-general | actions | 5 | 5 | The two lists are nearly identical and both are faithful: booking due Thursday, Speaker 1 checking the discount card, You texting Maria, Speaker 1 confirming the keys tonight, Speaker 1 checking the museum and messaging the group, and You sending the confirmation to trip.plans@example.com. Both correctly leave the booking without an owner. B's museum item ('whether it's open on Sundays') is slightly more precise. Neither report has placeholders. |
| scenario-general | insights | 4 | 5 | A gives three relevant, grounded suggestions: contact Maria before Thursday, check the museum's Sunday hours and have a fallback, and get the neighbour's details. B's keys backup suggestion is good. Its first point overstates the urgency, though: the plan to book Thursday already meets the 'by Friday' deadline, so 'only one day' adds little. B also misses the museum fallback. |
| scenario-interview | summary | 4 | 5 | Both are accurate. A leaves out your promise to send references tonight and doesn't say where the details and take-home will be sent. B covers all next steps, with the real addresses from the transcript (recruiting@example.com, hr.team@example.com). Neither has placeholders. |
| scenario-interview | questions | 5 | 5 | The two are identical and match the interviewer's five questions word for word. |
| scenario-interview | answers | 5 | 5 | Both report every answer faithfully, including the clock-skew caveat and the interviewer's praise for flagging it. B calls the disagreement answer 'hesitant', which the 'Um' in the transcript supports. |
| scenario-interview | gaps | 5 | 4 | A gives three well-grounded gaps with concrete, practical fixes. B covers the same three and adds a project-answer gap, but it's speculative (B marks it unsure). B's sample disagreement answer also scripts details that didn't happen, like 'I ran a small test', though it warns you to use only true details. |
| scenario-interview | follow_ups | 3 | 5 | A says to 'watch recruiting@example.com', which reads as if you own that inbox. It's most likely the company's recruiting address, and that clashes with A naming Speaker 1 as owner. A also lists 'read up on distributed rate limiting', which nobody committed to in the interview. B lists only what was said and adds a sensible unsure note about how the materials will reach you. |
| scenario-interview | insights | 4 | 5 | Both give reasonable advice, clearly labelled as AI suggestions. B is a little more useful: it adds advice on preparing for the take-home and on reviewing distributed rate limiting, which fits better here than in follow-ups. |
| scenario-lecture | summary | 5 | 4 | Both are accurate. A also includes the point that the gradient points toward steepest increase, so steps go the opposite way and can end in a local minimum, and it names the homework (chapter four, SGD on the toy dataset). B leaves out that point and only describes the homework vaguely. Neither report reproduces the tokenized URL or the email. |
| scenario-lecture | key_concepts | 4 | 5 | Both match the transcript closely. B also records that the lecturer wasn't sure about Adam's bias-correction details and pointed to the original paper, a caveat A leaves out. A's 'Adam is not the same as momentum' is faithful but less informative. |
| scenario-lecture | explanations | 5 | 4 | Both are faithful, and the 'More' text in each stays within reasonable background knowledge. A has a separate gradient descent entry and stronger momentum sources (Ruder, D2L). B's momentum sources (APXML, Ultralytics) are weaker. B's claim that Adam includes 'momentum-style averaging' goes slightly beyond what the lecturer said, though it's correct. I couldn't verify whether the source URLs work. |
| scenario-lecture | study_questions | 5 | 4 | Both are accurate. A has one more useful question, on what the gradient is and which way it points. B's Adam-vs-momentum answer is clear. There are no errors in either. |
| scenario-lecture | insights | 5 | 5 | The content is essentially the same: implement SGD with several learning rates, add momentum, and read the Adam paper. Both are labeled as AI suggestions and match the transcript. |
| scenario-meeting | summary | 5 | 4 | Both are accurate and cover all three agenda items plus the open monitoring decision. B is more specific: it names Speaker 3 as owner of the staging shutdown, gives the $18,500 overspend and says how the on-call gap was filled (a swap). A leaves out the overspend figure. |
| scenario-meeting | who_said_what | 5 | 5 | Both are faithful and attribute statements correctly. A leaves out the email address and only says the list should be sent to Speaker 2. B keeps nadia.okafor@example.com as said in the transcript, which is accurate and useful. Neither repeats the phone number or the dashboard token, and neither has placeholders. |
| scenario-meeting | open_questions | 5 | 5 | Both list the same two open questions from the transcript: whether the 21st clashes with the audit window, and whether to renew or switch the monitoring vendor. Both correctly say neither was answered and name the follow-up owners. They are effectively the same. |
| scenario-meeting | actions | 5 | 4 | Both capture all the actions with the correct owners and due dates (Thursday, tonight, next Monday). A makes Speaker 1 the owner of updating the rota sheet, but 'Put it in the rota sheet' doesn't make clear who does it, so that's an assumption. B splits the swap into separate cover items with dates, marks the rota-sheet owner as unstated and includes the email to send the list to. B is more careful and more useful. |
| scenario-meeting | insights | 4 | 5 | Both give sensible suggestions that are clearly labelled as coming from the AI. A has a valuable security point: the dashboard token was read out in the meeting and should be treated as exposed, and A makes it without repeating the token. B adds a useful check for other idle environments and covers the missing owners for both the account list and the rota sheet, but it says nothing about the exposed token. |
| scenario-one_on_one | summary | 4 | 5 | Both are accurate. A is a bit more specific: it names Sam and says docs arrive too late for people to comment. It also addresses the reader directly as 'You'. B's 'the user' phrasing is awkward in a personal report, and it says 'a new hire' instead of naming Sam. |
| scenario-one_on_one | feedback | 4 | 5 | Both are faithful and quote the transcript correctly. A also records the manager's point that the tech lead gap is mostly scope and influence across teams. B leaves that out but correctly adds that Speaker 1 took ownership of the priorities request ('I own it'). |
| scenario-one_on_one | commitments | 5 | 5 | The two are nearly identical, and every owner and the Wednesday due date are correct. A's wording 'possible cross-team project' is slightly more careful, and it notes that Speaker 1 agreed to the mentoring. Neither invents anything. |
| scenario-one_on_one | growth | 5 | 5 | Both are accurate and complete. B folds the scope and influence gap into the first item and links the cross-team project to the build-cache work, marked as 'possibly'. A notes that Speaker 1 encouraged the mentoring and quotes the full line. |
| scenario-one_on_one | follow_ups | 5 | 4 | Both flag that 'all three things' is ambiguous, which is good. A adds a follow-up to revisit on-call load, but nobody agreed to that in the meeting. A says so itself, so it isn't invented, but it belongs with the AI insights, where it already appears. B lists only the check-in that was actually agreed. |
| scenario-one_on_one | insights | 5 | 5 | Both make the same two sound points: the on-call concern got no action, and the new work adds to the load. Both are labeled as AI suggestions. A speaks to the reader as 'you', and B uses 'the user'. Neither report includes the email address or phone number, and neither has leftover placeholders. |
| scenario-therapy | summary | 4 | 5 | Both are accurate and invent nothing. A is shorter and says only that they 'agreed on a small plan', without giving it. B gives the plan (defusion phrase and rehearsing the opening) and the client's trouble saying no to their sister, so it is more useful. B calls defusion 'a way of creating distance' at first but names it later. Neither includes the office phone number or email, which is appropriate. |
| scenario-therapy | issues | 5 | 5 | The two are almost the same. Both list all three issues the client raised and back each one with an accurate quote. |
| scenario-therapy | suggestions | 4 | 5 | Both are faithful. A merges the values question and the write-three-actions exercise into one item. B lists them separately, which is closer to how the transcript runs, and it keeps the 'Maybe' in the agreed-goal quote. Both correctly record that the sister issue was put off to next session. |
| scenario-therapy | todos | 5 | 4 | Both list the same three items and correctly mark the values exercise as uncertain, since the client never explicitly agreed to it. A's due date 'before Friday' matches the transcript. B's 'Friday' is slightly less exact. |
| scenario-therapy | smart_goals | 5 | 5 | The two are identical. Both state the goal the client explicitly agreed to, with an accurate quote and the Friday deadline. |
| scenario-therapy | concepts | 5 | 4 | Both explain cognitive defusion correctly and give the same sources. A also gives sources for values-based action. B's values entry has none, which makes it less useful, though B's quote does use the transcript's own words 'values exercise'. A's 'less like a command' adds a little interpretation. I could not check whether the links work. A's AddictionHelp source is less authoritative than the others. |
| scenario-therapy | insights | 5 | 4 | Both cover each issue, hedge appropriately and are grounded in the transcript. A's point about catching the cycle early through the tight chest is useful, and it says openly that the sister suggestion was not discussed. B's tip to practise at a calm time of day is reasonable. Its closing 'This is only one account of the situation' reads a little oddly. |

**Sections rated worse with regex (the user sees these before merge):**
- scenario-general · summary: 4 with regex, 5 without
- scenario-general · who_said_what: 4 with regex, 5 without
- scenario-general · open_questions: 4 with regex, 5 without
- scenario-general · insights: 4 with regex, 5 without
- scenario-interview · summary: 4 with regex, 5 without
- scenario-interview · follow_ups: 3 with regex, 5 without
- scenario-interview · insights: 4 with regex, 5 without
- scenario-lecture · key_concepts: 4 with regex, 5 without
- scenario-meeting · insights: 4 with regex, 5 without
- scenario-one_on_one · summary: 4 with regex, 5 without
- scenario-one_on_one · feedback: 4 with regex, 5 without
- scenario-therapy · summary: 4 with regex, 5 without
- scenario-therapy · suggestions: 4 with regex, 5 without

**Problems:** none.

## Reading this run (added by hand)
- **Unsure:** this run didn't record which report the rater saw as A, so a note's "A" can't be tied to with or without regex. The scores in the two columns are mapped correctly. Later runs add an "A was" column.
- **Rated worse with regex:** 13 of 32 sections, all by one point except `scenario-interview · follow_ups` (3 vs 5). **Rated better with regex:** 10 sections, all by one point. 9 the same.
- Several "worse" notes are about a value being left out, such as a confirmation email address. With regex the model sees a token such as `<EMAIL_1>` and may drop it rather than copy it. That's a real but mild cost of redaction, as M2 found; the fact checks kept 42 of 42 facts with regex and 41 of 42 without.
- Every scenario was classified as expected, both ways. Topics differ in wording on 4 of 6, with the same subject. No token was lost or left in a report.
- One run per side, so a one-point gap is within run-to-run noise. Read this as direction, not proof.
