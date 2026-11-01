# Keep Awake demo

The animated Keep Awake scene on the website (`docs/#awake`). Built with the
Stageshow kit (`kit/`) and Preact, into `docs/awake-demo.js` and `docs/awake-demo.css`.

    cd web/awake-demo && npm install && npm run build

Scene: `scene/index.tsx` (beats and copy), `scene/keep-awake.css` (look).
A MacBook Pro in two acts: without Keep Awake (lid closes, Mac sleeps, tests
stuck at 148/212 next morning), then with it (notch, cup, lid switch, password
once, agents ship all night). Wide design 1040 x 680; below 720px a phone
design pushes in on the notch while it's used. Reduced motion shows one still:
3:15 AM, lid closed, agents still going.

`index.html` is a dev page: `npx vite` serves it.

## Rehearsal notes

- Started from the `dark-hero` and `dynamic-island` examples: one black notch
  shape that springs between bar, home, the Keep Awake page and done, with
  content on its own layer. Header, page and password box copy match the app.
- Filmed wide (1280) and phone (390) on the real page; every beat, the loop
  seam (the Mac naps to black, wakes on the first frame) and the poster.
- Known film lines left on purpose: the notch sits at 0px from the top (it is
  the hardware notch), and jumps at the nap happen under the black screen.
- Not checked: Safari and Firefox by hand.
