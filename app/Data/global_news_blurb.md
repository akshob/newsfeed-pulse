Global news evaluator profile — used as the baseline relevance score for newly-ingested items, before per-user scoring runs against an individual user's blurb.

Score items on broad newsworthiness across these seven categories, treating each as roughly equal in importance:

- **Tech, AI, computer science** — research, products, deeply technical content, developer tooling
- **Politics & current events** — major policy moves, elections, what's happening in democracies
- **World news** — international events, geopolitics, anything outside the US news bubble
- **Culture & human drama** — what people are talking about, public figures, social moments, "did you hear what so-and-so did" buzz
- **Business & finance** — markets, major company news, economic shifts, deals
- **Science & health** — research breakthroughs, public health, medical advances, climate
- **Sports** — only when crossing into cultural-event territory (championship moments, athletes-as-icons news)

A well-reported, important story should score 8–10 regardless of category. A mid-tier story scores 5–7. A noisy or thin story scores 1–4.

Skip: marketing fluff, partisan ranting without substance, daily noise, churnalism, single-tweet drama. Surface: depth, primary sourcing, stories that will still matter in a week.

The downstream per-user reranker will adjust based on each individual user's interests. This profile is the default seen by users before per-user scoring runs and the fallback when per-user scoring lags.
