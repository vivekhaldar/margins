// Semantic summaries and history share a reversible display surface, not document state.
(() => {
  'use strict';
  const root = typeof window === 'undefined' ? globalThis : window;
  const HEADINGS = 'h1,h2,h3,h4,h5,h6';
  const SOURCE_ATTRS = ['data-source-bid', 'data-source-block-id', 'data-source-block', 'data-source-heading'];
  const EXCLUDED = '.chg > del,.diff-removed,.tools,.rb,pre,table,figure,img,script,style,svg,math,input,button';
  const TAGS = new Set('h1 h2 h3 h4 h5 h6 p ul ol li blockquote pre table thead tbody tfoot tr th td caption figure figcaption dl dt dd strong em b i s u mark small sub sup del ins q cite abbr time kbd code a img br hr span div'.split(' '));
  const UNWRAP_TAGS = new Set('section article main header footer aside nav'.split(' '));
  const SVG_TAGS = new Set('svg g title desc path rect circle ellipse line polyline polygon text tspan defs marker lineargradient radialgradient stop'.split(' '));
  const SVG_ATTRS = new Set('xmlns viewbox width height x y x1 y1 x2 y2 cx cy r rx ry d points fill stroke stroke-width stroke-dasharray stroke-linecap stroke-linejoin opacity fill-opacity stroke-opacity transform text-anchor dominant-baseline font-size font-family font-weight dx dy offset stop-color stop-opacity marker-end marker-start markerwidth markerheight refx refy orient preserveaspectratio aria-label role id'.split(' '));

  function countWords(text) {
    return (String(text || '').match(/[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/gu) || []).length;
  }

  function proseText(el) {
    const clone = el.cloneNode(true);
    clone.querySelectorAll(EXCLUDED).forEach(node => node.remove());
    clone.querySelectorAll('*').forEach(node => { node.before(' '); node.after(' '); });
    return clone.textContent;
  }

  function safeURL(value, image) {
    if (!value || /[\s\\\u0000-\u001f\u007f]/u.test(value)) return false;
    if (value.startsWith('#')) return !image;
    try {
      const url = new URL(value);
      if (['http:', 'https:'].includes(url.protocol)) return !!url.hostname && !url.username && !url.password;
      if (image && url.protocol === 'margins-asset:') {
        return url.hostname === 'img' && /^\/[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$/.test(url.pathname) && !url.search && !url.hash;
      }
      return !image && url.protocol === 'mailto:' && !!url.pathname;
    } catch (_) { return false; }
  }

  function keepAttribute(node, attr, inSVG) {
    const attrName = attr.name.toLowerCase();
    if (inSVG) {
      if (attrName === 'xmlns') return attr.value === 'http://www.w3.org/2000/svg';
      return SVG_ATTRS.has(attrName);
    }
    if (SOURCE_ATTRS.includes(attrName)) return true;
    if (['title', 'id'].includes(attrName)) return true;
    const tag = node.tagName.toLowerCase();
    if (attrName === 'href') return tag === 'a' && safeURL(attr.value, false);
    if (attrName === 'src') return tag === 'img' && safeURL(attr.value, true);
    if (tag === 'img') return ['alt', 'width', 'height'].includes(attrName);
    if (['td', 'th'].includes(tag)) return ['colspan', 'rowspan', 'scope'].includes(attrName);
    return tag === 'ol' && attrName === 'start';
  }

  function summaryHTML(html) {
    const template = document.createElement('template');
    template.innerHTML = html || '';
    template.content.querySelectorAll('script,style,iframe,object,embed,link,meta,math,form,input,button,foreignObject,use,image,animate,set')
      .forEach(node => node.remove());
    template.content.querySelectorAll('svg a').forEach(node => node.remove());
    // Walk bottom-up so unwrapping benign container tags preserves sanitized children.
    const nodes = [...template.content.querySelectorAll('*')].reverse();
    for (const node of nodes) {
      const tag = node.tagName.toLowerCase();
      const inSVG = tag === 'svg' || !!node.closest('svg');
      if (!inSVG && UNWRAP_TAGS.has(tag)) {
        node.replaceWith(...node.childNodes);
        continue;
      }
      const allowed = inSVG ? SVG_TAGS.has(tag) : TAGS.has(tag);
      if (!allowed) { node.remove(); continue; }
      [...node.attributes].forEach(attr => {
        if (!keepAttribute(node, attr, inSVG)) node.removeAttribute(attr.name);
      });
    }
    return template.innerHTML;
  }

  const headingText = node => (node?.textContent || '').replace(/\s+/g, ' ').trim();
  const clone = value => value == null ? value : JSON.parse(JSON.stringify(value));

  class Display {
    constructor(deps) {
      this.deps = deps;
      this.doc = deps.doc;
      this.scroll = document.getElementById('scroll');
      this.saved = this.savedNodes = this.mode = this.timer = this.lastCount = null;
      this.annotationEnabled = false;
      this.scrollPosition = 0;
      this.bindEvents();
    }

    isSemanticZoom() { return this.mode === 'semantic'; }
    savedSnapshot() { return clone(this.saved); }
    savedHTML() { return this.isSemanticZoom() ? this.saved?.html : null; }
    headings() { return [...this.doc.querySelectorAll(HEADINGS)].filter(node => !node.closest('.chg > del,.diff-removed')); }

    nearestHeading(node) {
      const list = this.headings(), own = node?.closest(HEADINGS);
      if (own && list.includes(own)) return own;
      return list.filter(heading => heading.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING).pop() || null;
    }

    visibleAnchorHeading() {
      const top = this.scroll.getBoundingClientRect().top + 16, list = this.headings();
      return headingText(list.filter(node => node.getBoundingClientRect().top <= top).pop() || list[0]) || null;
    }

    scrollTo(blockId, heading) {
      const block = blockId && [...this.doc.querySelectorAll('[data-bid]')].find(node => node.dataset.bid === blockId);
      const anchor = block || (heading && this.headings().find(node => headingText(node) === heading));
      if (anchor) anchor.scrollIntoView({block: 'start', behavior: root.MarginsTheme?.reducedMotion() ? 'auto' : 'smooth'});
    }

    controls(on) {
      document.body.classList.toggle('semantic-zoom', on);
      this.doc.setAttribute('aria-readonly', String(on || this.mode === 'history'));
      for (const id of ['bar', 'annotation-layer', 'annotation-card', 'zenpill']) {
        document.getElementById(id)?.toggleAttribute('inert', on);
      }
      if (on) {
        root.getSelection()?.removeAllRanges();
        if (!this.annotationEnabled) this.annotationEnabled = root.MarginsAnnotationUI?.isEnabled() || false;
        root.MarginsAnnotationUI?.setEnabled(false);
        root.MarginsAnnotationUI?.close(false);
      } else if (this.annotationEnabled) {
        root.MarginsAnnotationUI?.setEnabled(true);
        this.annotationEnabled = false;
      }
    }

    capture() {
      this.deps.flush();
      if (this.saved) return;
      this.deps.annotationEngine()?.sync({silent: true});
      this.saved = {html: this.deps.currentHTML(), annotations: this.deps.annotationEngine()?.snapshot()};
      this.savedNodes = document.createDocumentFragment();
      this.scrollPosition = this.scroll.scrollTop;
      this.savedNodes.append(...this.doc.childNodes);
    }

    display(html, annotations, kind) {
      this.capture();
      this.mode = kind;
      this.doc.innerHTML = html;
      this.doc.contentEditable = 'false';
      this.doc.classList.add('ro');
      document.body.classList.toggle('previewing', kind === 'history');
      this.controls(kind === 'semantic');
      // Summary text never enters attribution state or its undo history.
      if (kind === 'history') this.deps.annotationEngine()?.load(annotations);
      this.deps.dismiss();
      this.deps.refresh();
    }

    reset() {
      this.saved = this.savedNodes = this.mode = null;
      document.body.classList.remove('previewing', 'semantic-zoom-loading');
      this.controls(false);
      this.doc.removeAttribute('aria-readonly');
      this.lastCount = null;
    }

    endPreview() {
      if (!this.saved) return;
      const original = this.saved, wasHistory = this.mode === 'history';
      this.doc.replaceChildren(this.savedNodes);
      this.reset();
      this.doc.contentEditable = 'true';
      this.doc.classList.remove('ro');
      this.deps.restore();
      if (wasHistory) this.deps.annotationEngine()?.load(original.annotations);
      this.scroll.scrollTop = this.scrollPosition;
      this.reportWords();
    }

    preview(html, annotations) {
      if (this.isSemanticZoom()) this.endPreview();
      this.display(html, annotations, 'history');
    }

    setSemanticZoomLoading(percentage) {
      if (![10, 25, 50, 75].includes(Number(percentage))) return false;
      if (this.mode === 'history') this.endPreview();
      if (!this.isSemanticZoom()) {
        this.capture();
        this.mode = 'semantic';
        const previewClone = this.savedNodes.cloneNode(true);
        previewClone.querySelectorAll('.tools').forEach(node => node.remove());
        this.doc.replaceChildren(previewClone);
        this.doc.contentEditable = 'false';
        this.doc.classList.add('ro');
        document.body.classList.remove('previewing');
        this.controls(true);
        this.deps.dismiss();
        this.deps.refresh();
        this.scroll.scrollTop = this.scrollPosition;
      }
      document.body.classList.add('semantic-zoom-loading');
      return true;
    }

    setSemanticZoom(html, percentage, anchorHeading) {
      if (![10, 25, 50, 75].includes(Number(percentage))) return false;
      const anchor = anchorHeading || this.visibleAnchorHeading();
      if (this.mode === 'history') this.endPreview();
      document.body.classList.remove('semantic-zoom-loading');
      this.display(summaryHTML(html), {spans: [], runs: [], comments: []}, 'semantic');
      this.scrollTo(null, anchor);
      return true;
    }

    clearSemanticZoom(scrollToBlockId, anchorHeading) {
      if (!this.isSemanticZoom()) return;
      const anchor = anchorHeading || this.visibleAnchorHeading();
      this.endPreview();
      this.scrollTo(scrollToBlockId, anchor);
    }

    sourceFor(node) {
      const block = node.closest('p,' + HEADINGS);
      if (!block || !this.doc.contains(block)) return null;
      const heading = headingText(this.nearestHeading(block));
      const source = block.closest(SOURCE_ATTRS.slice(0, 3).map(attr => '[' + attr + ']').join(','));
      const blockId = source && SOURCE_ATTRS.slice(0, 3).map(attr => source.getAttribute(attr)).find(Boolean);
      return {blockId: blockId || null, heading: block.getAttribute('data-source-heading') || heading || null};
    }

    sourceEvent(event) {
      if (!this.isSemanticZoom()) return;
      const node = event.target.nodeType === 1 ? event.target : event.target.parentElement;
      if (!(event.type === 'click' ? node.closest(HEADINGS) : node.closest('p'))) return;
      const source = this.sourceFor(node);
      if (!source) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      root.getSelection()?.removeAllRanges();
      this.deps.post('semanticZoomSource', source);
    }

    guardEvent(event) {
      if (!this.isSemanticZoom()) return;
      const inDocument = this.doc.contains(event.target);
      const control = event.target.closest?.('#bar,#annotation-layer,#annotation-card,#zenpill,.pop,.lpop,.tpop,.askchip,.commentchip');
      if (!control && !inDocument) return;
      if (inDocument && event.type === 'keydown' && ['Tab', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End'].includes(event.key) && !event.metaKey && !event.ctrlKey) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    }

    liveWordCount() { return countWords(proseText(this.savedNodes || this.doc)); }
    reportWords() {
      clearTimeout(this.timer); this.timer = null;
      const wordCount = this.liveWordCount();
      if (wordCount !== this.lastCount) { this.lastCount = wordCount; this.deps.post('liveWordCount', {wordCount}); }
    }
    scheduleWords() {
      if (!this.saved && !this.timer) this.timer = setTimeout(() => this.reportWords(), 150);
    }

    bindEvents() {
      new MutationObserver(() => this.scheduleWords()).observe(this.doc, {childList: true, characterData: true, subtree: true});
      for (const type of ['beforeinput', 'input', 'paste', 'drop', 'cut', 'keydown', 'contextmenu']) {
        root.addEventListener(type, event => this.guardEvent(event), true);
      }
      root.addEventListener('click', event => {
        if (this.isSemanticZoom() && !this.doc.contains(event.target)) this.guardEvent(event);
      }, true);
      this.doc.addEventListener('click', event => this.sourceEvent(event), true);
      this.doc.addEventListener('dblclick', event => this.sourceEvent(event), true);
      document.addEventListener('selectionchange', () => {
        const selection = root.getSelection();
        if (this.isSemanticZoom() && this.doc.contains(selection?.anchorNode)) selection.removeAllRanges();
      });
    }
  }

  function create(deps) {
    const display = new Display(deps);
    return Object.fromEntries(['preview', 'endPreview', 'reset', 'setSemanticZoomLoading', 'setSemanticZoom', 'clearSemanticZoom',
      'visibleAnchorHeading', 'liveWordCount', 'savedSnapshot', 'savedHTML', 'isSemanticZoom', 'reportWords']
      .map(name => [name, display[name].bind(display)]));
  }

  root.MarginsSemanticZoom = {create, countWords, proseText, summaryHTML};
})();
