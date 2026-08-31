/* Kite — Theme synchronization across iframes */
(function() {
  const root = document.documentElement;
  const apply = () => {
    const t = localStorage.getItem('kite-theme') || 'dark';
    const isDark = t === 'dark' || (t === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
    root.setAttribute('data-theme', isDark ? 'dark' : 'light');
  };
  apply();
  window.addEventListener('storage', (e) => {
    if (e.key === 'kite-theme') apply();
  });
})();
