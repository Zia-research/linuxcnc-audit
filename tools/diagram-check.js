/* diagram-check.js — geometry and semantics checks for the hand-written SVG figures.
 *
 * Why this exists: four separate checkers were written inline during the 2026-08-06
 * session and three of them were WRONG on first run — one measured x-overlap on
 * vertical segments (always zero, so it silently passed everything), one accepted any
 * point inside a large frame as a valid arrow landing, one never noticed a frame that
 * excluded its own members. Every check below therefore ships with a self-test that
 * must catch a known-bad case before the run is allowed to count.
 *
 * Usage, from the page:            diagramCheck()
 *   verbose (list every landing):  diagramCheck({verbose:true})
 *   only one scheme:               diagramCheck({schemes:['A']})
 *
 * Defaults assume:  rect.grp = grouping frame (a region, not a target)
 *                   rect.plain = decorative inner box, exempt from containment
 *                   rect.straddle = deliberately crosses two frames
 * Override with:    diagramCheck({frameClass:'grp', straddleClass:'straddle'})
 *
 * Containment rules are declared by the page, e.g.
 *   diagramCheck({containment:[{frameY:26, memberClass:'mem-nrt', name:'non-realtime'},
 *                              {frameY:420, memberClass:'mem-rt',  name:'rtapi'}]})
 * frameY identifies the frame by its rounded y coordinate.
 *
 * memberClass must name a class that carries NO styling. Until 2026-08-07 the
 * colour-schemes page used its scheme-A colour classes (a1, a2) as membership
 * markers — one class doing two jobs. Deleting the colour scheme deleted the
 * markers, and this check went on reporting clean while testing nothing at all.
 * KNOWN BLIND SPOT, deliberately left unguarded for now: a rule whose memberClass
 * matches zero elements is silently vacuous. That is the same failure the self-test
 * below was written to prevent elsewhere, so until the guard exists, confirm the
 * member count yourself before trusting a clean verdict.
 */
(function (global) {
  const PAD = 2;      // px of tolerance before a line counts as crossing a box
  const NEAR = 6;     // px within which an arrow tip counts as having landed

  const box = el => { const b = el.getBBox();
    return { x: b.x, y: b.y, w: b.width, h: b.height,
             tag: '@' + Math.round(b.x) + ',' + Math.round(b.y) }; };

  const distOutside = (px, py, r) =>
    Math.hypot(Math.max(r.x - px, 0, px - (r.x + r.w)), Math.max(r.y - py, 0, py - (r.y + r.h)));

  // distance to the PERIMETER: outside → straight distance; inside → nearest edge.
  // The difference matters: a point deep inside a frame has NOT landed on it.
  const distPerimeter = (px, py, r) => {
    const out = distOutside(px, py, r);
    return out > 0 ? out : Math.min(px - r.x, r.x + r.w - px, py - r.y, r.y + r.h - py);
  };

  const overlaps = (a, b, tol) =>
    Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > tol &&
    Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) > tol;

  const encloses = (F, b) =>
    b.x >= F.x - 1 && b.y >= F.y - 1 && b.x + b.w <= F.x + F.w + 1 && b.y + b.h <= F.y + F.h + 1;

  // Split an orthogonal path ("M x,y H a V b …") into axis-aligned segments.
  //
  // The `-?` in all three patterns below was missing until 2026-08-07, and its
  // absence was SILENT: a path with a negative coordinate failed ORTHO, was
  // dropped from `paths` by the filter in scan(), and was never mentioned. It
  // did not fail — it ceased to exist. In linuxcnc-system-overview.html exactly
  // one connector qualified, "M252,240 H-60 V830 H204", the halui → HAL memory
  // link that routes through the negative-x gutter the page documents as a
  // deliberate choice. So the one routing decision that figure argues for was
  // the one connector never checked, for crossings or for landings, across
  // every clean run it ever reported.
  // The tell was a persistent off-by-one between this checker's `paths` count
  // and a count taken outside it. A checker that quietly narrows its own input
  // is worse than one that errors: this is the same disease as a containment
  // rule whose member class matches nothing and passes.
  const ORTHO = /^M-?[\d.]+,-?[\d.]+( [HV]-?[\d.]+)+$/;
  function segmentsOf(d) {
    const m = d.match(/^M(-?[\d.]+),(-?[\d.]+)(.*)$/);
    let x = +m[1], y = +m[2]; const out = [];
    m[3].trim().split(/\s+/).forEach(tok => {
      const nx = tok[0] === 'H' ? +tok.slice(1) : x;
      const ny = tok[0] === 'V' ? +tok.slice(1) : y;
      out.push({ x1: x, y1: y, x2: nx, y2: ny }); x = nx; y = ny;
    });
    return out;
  }
  const endOf   = d => { const s = segmentsOf(d); const l = s[s.length - 1]; return [l.x2, l.y2]; };
  const startOf = d => { const m = d.match(/^M(-?[\d.]+),(-?[\d.]+)/); return [+m[1], +m[2]]; };

  // Does an axis-aligned segment cross a rectangle's interior?
  // Handles BOTH orientations — the bug that made the first version certify nothing.
  function crosses(seg, r) {
    const vert = seg.x1 === seg.x2;
    const lo = vert ? Math.min(seg.y1, seg.y2) : Math.min(seg.x1, seg.x2);
    const hi = vert ? Math.max(seg.y1, seg.y2) : Math.max(seg.x1, seg.x2);
    const fixed = vert ? seg.x1 : seg.y1;
    const bx1 = r.x + PAD, bx2 = r.x + r.w - PAD, by1 = r.y + PAD, by2 = r.y + r.h - PAD;
    if (bx2 <= bx1 || by2 <= by1) return 0;
    const withinFixed = vert ? (fixed > bx1 && fixed < bx2) : (fixed > by1 && fixed < by2);
    if (!withinFixed) return 0;
    const a = vert ? by1 : bx1, b = vert ? by2 : bx2;
    return Math.max(0, Math.min(hi, b) - Math.max(lo, a));
  }

  function scan(svg, opt) {
    const frameClass = opt.frameClass || 'grp';
    const straddleClass = opt.straddleClass || 'straddle';
    const rects = [...svg.querySelectorAll('rect')].map(el => Object.assign(box(el), {
      el, frame: el.classList.contains(frameClass),
      plain: el.classList.contains('plain'),
      straddle: el.classList.contains(straddleClass)
    }));
    rects.forEach(r => {
      r.leaf = !r.frame && !rects.some(o => o !== r && !o.frame && encloses(o, r) && o !== r && o.w * o.h > r.w * r.h);
    });
    const texts = [];
    svg.querySelectorAll('text').forEach(el => {
      if (getComputedStyle(el).display === 'none') return;
      const b = box(el); if (b.w === 0) return;
      texts.push(Object.assign(b, { tag: '"' + el.textContent.trim().slice(0, 34) + '"' }));
    });
    const paths = [...svg.querySelectorAll('path[d^="M"]')]
      .filter(p => ORTHO.test(p.getAttribute('d')));
    return { rects, texts, paths, leaves: rects.filter(r => r.leaf && !r.frame) };
  }

  function runScheme(svg, opt) {
    const { rects, texts, paths, leaves } = scan(svg, opt);
    const errs = [];

    // 1 · lines must not cross leaf boxes or text
    paths.forEach(p => segmentsOf(p.getAttribute('d')).forEach(s => {
      leaves.forEach(r => { const px = crosses(s, r); if (px) errs.push(`line ${p.getAttribute('d')} crosses box ${r.tag} (${Math.round(px)}px)`); });
      texts.forEach(t => { const px = crosses(s, t); if (px) errs.push(`line ${p.getAttribute('d')} crosses text ${t.tag} (${Math.round(px)}px)`); });
    }));
    // 2 · boxes must not overlap each other; text must not overlap text
    for (let i = 0; i < leaves.length; i++) for (let j = i + 1; j < leaves.length; j++)
      if (overlaps(leaves[i], leaves[j], 1) && !(leaves[i].straddle || leaves[j].straddle))
        errs.push(`boxes overlap: ${leaves[i].tag} ∩ ${leaves[j].tag}`);
    for (let i = 0; i < texts.length; i++) for (let j = i + 1; j < texts.length; j++)
      if (overlaps(texts[i], texts[j], 2)) errs.push(`text overlaps: ${texts[i].tag} ∩ ${texts[j].tag}`);

    // 3 · every arrowhead must land on a leaf box, or on a frame's EDGE (never its interior)
    const land = pt => {
      for (const r of rects) {
        if (!r.frame && distOutside(pt[0], pt[1], r) <= NEAR) return r.tag;
        if ( r.frame && distPerimeter(pt[0], pt[1], r) <= NEAR) return 'FRAME ' + r.tag;
      }
      return null;
    };
    const landings = [];
    paths.forEach(p => {
      const d = p.getAttribute('d');
      if (p.getAttribute('marker-end')) {
        const t = land(endOf(d)); landings.push({ d, at: 'end', onto: t });
        if (!t) errs.push(`arrow ends in open space: ${d} → (${endOf(d).map(Math.round)})`);
      }
      if (p.getAttribute('marker-start')) {
        const t = land(startOf(d)); landings.push({ d, at: 'start', onto: t });
        if (!t) errs.push(`arrow starts in open space: ${d}`);
      }
    });

    // 4 · a double-headed arrow must actually RENDER double-headed
    const mk = svg.querySelector('marker');
    const bidi = paths.filter(p => p.getAttribute('marker-start') && p.getAttribute('marker-end')).length;
    if (bidi && mk && mk.getAttribute('orient') === 'auto')
      errs.push(`${bidi} bidirectional arrows, but marker orient="auto" — the start head is drawn ALONG the path, so both heads point the same way. Use orient="auto-start-reverse".`);

    // 5 · containment — a labelled frame is an assertion about membership.
    //     Vacuous, and silently so, when memberClass matches nothing: the loop just
    //     finds no members and the scheme still reports clean. See the header note.
    (opt.containment || []).forEach(rule => {
      const F = rects.find(r => r.frame && Math.round(r.y) === rule.frameY);
      if (!F) { errs.push(`containment rule names no frame at y=${rule.frameY}`); return; }
      rects.filter(r => !r.frame && !r.plain).forEach(r => {
        if (r.straddle) return;
        if (r.el.classList.contains(rule.memberClass) && !encloses(F, r))
          errs.push(`${rule.name}: ${r.tag} is declared a member but lies outside the frame`);
      });
    });
    // 6 · a straddling box must reach BOTH frames and be enclosed by neither
    if ((opt.containment || []).length >= 2) {
      const [A, B] = opt.containment.slice(0, 2)
        .map(rule => rects.find(r => r.frame && Math.round(r.y) === rule.frameY));
      rects.filter(r => r.straddle).forEach(r => {
        if (A && B && !(overlaps(A, r, 1) && overlaps(B, r, 1)))
          errs.push(`straddle box ${r.tag} does not reach both domains`);
        if ((A && encloses(A, r)) || (B && encloses(B, r)))
          errs.push(`straddle box ${r.tag} is fully enclosed by one domain`);
      });
    }
    // 7 · reachability — every box must be wired into the machine graph, or SAY
    //     that it is not. Rule 3 asks whether an arrow lands on a box; nothing
    //     asked whether a box is REACHED by an arrow, and that blind spot let the
    //     drivers and the machine sit as an island for as long as the figure
    //     existed. Two questions, two different defects: dangling arrows, and
    //     dangling boxes.
    //     It is a COMPONENT test, not an orphan test, and the difference matters:
    //     a detached side panel may be wired internally (wizards → the two config
    //     files) and still be off the machine graph. Counting connectors would
    //     call that reachable; counting components does not.
    //     Falsifiable both ways on purpose: an undeclared box off the main graph
    //     fails, AND a box that declares itself detached while wired into the main
    //     graph fails too — otherwise the declaration would rot silently the day
    //     someone reconnects it.
    const detachedClass = opt.detachedClass || 'detached';
    const componentsOf = (extraIsolated) => {
      const idx = new Map(rects.map((r, i) => [r, i]));
      const adj = rects.map(() => []);
      const link = (a, b) => { adj[idx.get(a)].push(idx.get(b)); adj[idx.get(b)].push(idx.get(a)); };
      rects.forEach(r => {                       // a box belongs to its container
        let best = null;
        rects.forEach(o => {
          if (o === r || !encloses(o, r) || o.w * o.h <= r.w * r.h) return;
          if (!best || o.w * o.h < best.w * best.h) best = o;
        });
        if (best) link(r, best);
      });
      const rectAt = pt => {                     // an endpoint belongs to its box
        let best = null;
        for (const r of rects) {
          const d = r.frame ? distPerimeter(pt[0], pt[1], r) : distOutside(pt[0], pt[1], r);
          if (d <= NEAR && (!best || r.w * r.h < best.w * best.h)) best = r;
        }
        return best;
      };
      paths.forEach(p => {
        const d = p.getAttribute('d');
        const a = rectAt(startOf(d)), b = rectAt(endOf(d));
        if (a && b && a !== b) link(a, b);
      });
      const n = rects.length + (extraIsolated ? 1 : 0);
      const comp = new Array(n).fill(-1);
      let c = 0;
      for (let i = 0; i < n; i++) {
        if (comp[i] !== -1) continue;
        const stack = [i]; comp[i] = c;
        while (stack.length) {
          const u = stack.pop();
          (adj[u] || []).forEach(v => { if (comp[v] === -1) { comp[v] = c; stack.push(v); } });
        }
        c++;
      }
      return { comp, count: c };
    };
    const cc = componentsOf(false);
    // The rule's own falsifiability check. One isolated node added to the graph
    // must yield exactly one more component. If it does not, the adjacency has
    // collapsed everything into a single blob, this rule bites on nothing, and a
    // clean verdict from it would mean nothing — the vacuous-rule failure this
    // project has already met twice (the zero-member containment rule, and ORTHO
    // silently dropping every path with a negative coordinate).
    if (componentsOf(true).count !== cc.count + 1)
      errs.push('RULE 7 IS VACUOUS: an isolated node did not create a component — ' +
                'component detection is broken; disregard any clean verdict from it');
    const size = {};
    cc.comp.forEach(k => { size[k] = (size[k] || 0) + 1; });
    const main = Object.keys(size).sort((a, b) => size[b] - size[a])[0];
    rects.forEach((r, i) => {
      const declared = r.el.classList.contains(detachedClass);
      const offMain = String(cc.comp[i]) !== String(main);
      if (offMain && !declared)
        errs.push(`box ${r.tag} is on no path to the machine graph and does not declare class="${detachedClass}"`);
      if (!offMain && declared)
        errs.push(`box ${r.tag} declares class="${detachedClass}" but is wired into the main graph — stale declaration`);
    });

    return { errs, landings, counts: { boxes: leaves.length, texts: texts.length, paths: paths.length,
                                       components: cc.count } };
  }

  // The self-test: hand the checker defects it MUST catch. If it does not, its
  // clean bill of health means nothing and the run is refused.
  function selfTest(svg, opt) {
    const { rects, leaves } = scan(svg, opt);
    const fails = [];
    const vert = { x1: 0, y1: 0, x2: 0, y2: 0 };
    if (leaves.length) {                                    // a vertical line straight through a box
      const r = leaves[0];
      Object.assign(vert, { x1: r.x + r.w / 2, y1: r.y - 50, x2: r.x + r.w / 2, y2: r.y + r.h + 50 });
      if (!crosses(vert, r)) fails.push('crosses() blind to vertical segments');
      const horiz = { x1: r.x - 50, y1: r.y + r.h / 2, x2: r.x + r.w + 50, y2: r.y + r.h / 2 };
      if (!crosses(horiz, r)) fails.push('crosses() blind to horizontal segments');
    }
    const frame = rects.find(r => r.frame);
    if (frame) {                                            // deep inside a frame is NOT a landing
      const deep = [frame.x + frame.w / 2, frame.y + frame.h / 2];
      const hitsLeaf = leaves.some(r => distOutside(deep[0], deep[1], r) <= NEAR);
      if (!hitsLeaf && distPerimeter(deep[0], deep[1], frame) <= NEAR)
        fails.push('landing test accepts a frame interior');
    }
    return fails;
  }

  global.diagramCheck = function (opt) {
    opt = opt || {};
    const svg = opt.svg ? document.querySelector(opt.svg) : document.querySelector('svg');
    if (!svg) return { error: 'no svg found' };
    const st = selfTest(svg, opt);
    if (st.length) return { REFUSED: 'self-test failed — checker is broken', reasons: st };

    const schemes = opt.schemes ||
      (document.body.className.match(/^[A-Z]$/) ? ['A', 'B', 'C'] : [null]);
    const before = document.body.className;
    const out = schemes.map(s => {
      if (s) document.body.className = s;
      const r = runScheme(svg, opt);
      return { scheme: s || '(single)', ok: r.errs.length === 0, errors: r.errs, counts: r.counts,
               landings: opt.verbose ? r.landings : undefined };
    });
    document.body.className = before;
    const bad = out.filter(r => !r.ok);
    return bad.length
      ? { selfTest: 'passed', verdict: `${bad.length}/${out.length} scheme(s) FAIL`, detail: bad }
      : { selfTest: 'passed', verdict: `clean — ${out.length} scheme(s)`,
          counts: out[0].counts, landings: opt.verbose ? out[0].landings : undefined };
  };
})(window);
