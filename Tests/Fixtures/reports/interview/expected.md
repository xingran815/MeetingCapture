# Backend engineer interview

_Interview · 2027-01-15 08:00 · about 00:03:40 · reviewed_

## At a glance

- Tell me about a **project** you're proud of. _(Questions asked)_

## Summary

A backend **engineering** interview covering a past migration project, teamwork, a weakness, and a rate limiter design question. The interviewer will send the details of a take-home exercise.


## Questions asked

- **Speaker 1**: **Key:** Tell me about a **project** you're proud of.
- **Speaker 1**: How did you handle **disagreement** on the team?
- **Speaker 1**: What's a **weakness** you're working on?
- **Speaker 1**: How would you design a rate **limiter** for a public API?

## How you answered

- Led the **migration** of the reporting service to three smaller services, cutting the nightly job from six hours to forty minutes.
- Said they mostly kept going; one engineer **disagreed** about the database and the user's choice won.
- Takes on too much and is trying to **delegate**, with no good example yet.
- Token bucket per API key in Redis with a local cache; had not run the **distributed** version in production.

## Gaps and stronger answers

- **The disagreement answer did not show how the other engineer's view was heard.**
  - AI: Describe asking for the engineer's concerns, testing both database options on a small benchmark, and agreeing the result with the team.
- **No concrete example of delegating.**
  - AI: Prepare one example with the task, who took it, and the outcome. _(unsure: Only the user can know whether such an example exists.)_

## Follow-ups

- [ ] Expect the take-home **exercise** details by email on Monday (due: Monday)
- [ ] Send **references** to the recruiting contact tonight (due: tonight)

## AI insights
_Suggestions from the AI, not things that were said._

- AI: Raising the clock-skew **uncertainty** was received well; do it again, and add what you would read to close the gap.

## What the review changed

- Changed the references follow-up to say tonight. — The user said they would send them tonight.

---
> Note: 2 formatted value(s) were kept out of every request. Spoken names aren't caught.

Written by AI from an automatic transcript. Models — classify: Claude haiku, sections: Claude sonnet, review: Claude opus.
