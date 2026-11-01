# Keep Awake demo

The animated Keep Awake scene on the website (`docs/#awake`). Built with the
Stageshow kit (`kit/`) and Preact, into `docs/awake-demo.js` and `docs/awake-demo.css`.

    cd web/awake-demo && npm install && npm run build

Scene: `scene/index.tsx` (beats and copy), `scene/keep-awake.css` (look).
Wide design 1040 x 600; a phone design (358 wide) kicks in below 720px.
Reduced motion shows one still: 3:15 AM, lid closed, Codex on the next task.

## Rehearsal notes

- Started from the `dark-hero` and `dynamic-island` examples: one black notch
  shape that springs between bar, page and done, content on its own layer.
- Filmed wide (1280) and phone (390) on the real page; every beat, the loop
  seam (the Mac naps to black, wakes on the first frame) and the poster.
- Known film lines left on purpose: the notch sits at 0px from the top (it is
  the hardware notch), and jumps at the nap happen under the black screen.
- Not checked: Safari and Firefox by hand.
