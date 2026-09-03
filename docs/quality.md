# Turning grey into black and white

The head burns a dot or leaves the paper blank, so every grey in a document
has to become one or the other. Getting this wrong is what made pages arrive
faint, or with their borders missing.

## The head has two settings, and the wrong one looks faint

The profile carries two sets of head settings, and using the wrong one is the difference between crisp black text and a faint page:

| | energy | speed |
|---|---|---|
| text and line art | 33000 | 30 |
| photographs | 15000 | 40 |

Energy is the pulse the head is fired with, so text at the image setting is
printed at under half the heat it wants. Content is taken from IPP's
`print-content-optimize`: anything not explicitly a photograph is treated as
text, since that is what this printer is nearly always asked for.

## Form rules are drawn in grey, not black

A bilevel threshold at the obvious 128 deletes them: on one form, 344 of its 879 horizontal rules never
reached it, so the page printed with its borders missing while the text between
them came out perfectly. This is not antialiasing — rendered with antialiasing
off those rules are still grey. Documents simply draw their borders that way.

Where the threshold belongs was measured rather than guessed, over 22 pages of
real documents holding 16528 horizontal rules between them. The greys they are
drawn in cluster at 0, 8–10, 33–36, 110, 129, 145 and 160:

| threshold | rules printed |
|---|---|
| 128 | 71.8% |
| 144 | 84.3% |
| 160 | 89.1% |
| **176** | **99.5%** |
| 192–224 | 99.9% |

Two of the largest populations sit just above 128, which is what a 50%
threshold throws away. Text and line art are burned at 176: it clears the
highest common design grey, and from there the curve is flat, so a higher
level finds no more lines and only burns more of the page — past about 208 the
haloes around glyphs fill in, spending head energy and making the page look
heavier than it was drawn. Photographs are unaffected; they go through error
diffusion, where the same level would simply darken the picture.

The vendor's own tooling reaches the same conclusion from the other
direction: it error-diffuses everything by default, so a grey line prints as a
pattern of dots rather than being deleted, and its threshold mode is adaptive —
the page mean less 13, which on a white document lands near 220. Neither of its
paths uses 128. Measured on the form above, diffusing everything prints 854 of
page one's 879 rules against 874 for the threshold, the difference being that
diffused rules read as grey where thresholded ones are solid. Set
`mvb530-dither=diffuse` for that behaviour.

## Choosing between them

Both live on the **Print quality** page of the web interface, so neither needs
a config file or a restart; a change applies to the next page printed.

| Greys | What a grey rule does |
|---|---|
| Solid lines, shaded photographs | prints as a solid black line, or not at all |
| Shade everything | prints as a pattern of dots that reads as grey |
| Solid everywhere | as the first, photographs included |

The vendor's own tooling error-diffuses everything by default, which is why it
never loses a grey, and its threshold mode is adaptive — the page mean less 13,
landing near 220 on a white document. Neither of its paths uses 128 either.
Measured on the form above, shading everything prints 854 of page one's 879
rules against 874 for the threshold; the difference is that shaded rules read
as grey where solid ones are black.
