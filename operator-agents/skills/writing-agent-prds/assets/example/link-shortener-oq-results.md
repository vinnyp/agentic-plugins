# Open-question results: Link Shortener

One `## OQ <id>` section per answered open question, in ascending order. A section is added when
the question is answered; a question with no section here is still open, and its row in the PRD's
Open questions table is what a builder reads instead.

## OQ 1

**Question.** How long a destination does the product have to accept?

**Answered.** 2026-02-27, on an interim basis, by the example owner (F2).

**Finding.** The shortest destination length documented across the browsers R2.2 supports is
2,048 characters. No sample of real submitted destinations exists yet, so this example carries no
measured distribution and asserts none.

**Interim rule now in force.** R1.1 accepts a destination of at most 2,048 characters and rejects
a longer one. The copy under E2 states the limit without the number, because the number is what is
still open.

**What still closes it.** The length distribution of the destinations submitted during the first
dogfood week, read from the link manager's client event stream that M1 also reads. Until that
sample exists, R1.1 is built under the interim rule above and re-checked when the sample closes
the constant max-destination-length.
