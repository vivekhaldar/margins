// Applies a Margins theme (palette tokens + chrome) pushed from Swift via window.margins.setTheme.
(() => {
  'use strict';
  const root = document.documentElement;
  let applied = [];

  function apply(theme) {
    if (!theme || typeof theme !== 'object') return;
    applied.forEach((name) => root.style.removeProperty(name));
    applied = [];
    const vars = theme.vars && typeof theme.vars === 'object' ? theme.vars : {};
    Object.keys(vars).forEach((name) => {
      if (!/^--[a-z-]+$/.test(name) || typeof vars[name] !== 'string') return;
      root.style.setProperty(name, vars[name]);
      applied.push(name);
    });
    const scheme = theme.colorScheme === 'dark' ? 'dark' : 'light';
    root.dataset.colorScheme = scheme;
    root.style.colorScheme = scheme;
    root.dataset.sheetStyle = theme.sheetStyle === 'seamless' ? 'seamless' : 'card';
    const radius = Number(theme.cornerRadius);
    if (Number.isFinite(radius)) root.style.setProperty('--sheet-radius', Math.max(0, Math.min(radius, 24)) + 'px');
    if (theme.id) root.dataset.theme = String(theme.id);
    root.classList.add('themed');
  }

  const reducedMotion = () => !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

  // A brief tactile settle after accept/reject. Uses the Web Animations API so no class or
  // attribute ever lands on document content (nothing to strip during serialization).
  function settle(nodes, accepted) {
    if (reducedMotion() || !Array.isArray(nodes)) return;
    const tint = getComputedStyle(root).getPropertyValue(accepted ? '--ins' : '--accbg').trim();
    nodes.forEach((node) => {
      if (node.nodeType !== 1 || typeof node.animate !== 'function') return;
      node.animate(
        [{ backgroundColor: tint || 'transparent', opacity: accepted ? 1 : 0.6 }, { backgroundColor: 'transparent', opacity: 1 }],
        { duration: 180, easing: 'cubic-bezier(.2,.7,.3,1)' }
      );
    });
  }

  window.MarginsTheme = { apply, settle, reducedMotion };
})();
