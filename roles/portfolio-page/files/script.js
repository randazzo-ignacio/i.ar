/* ═══════════════════════════════════════════════════════════════════
   Ignacio Randazzo — Personal Portfolio
   JavaScript: scroll reveal, nav scroll effect, footer year
   ═══════════════════════════════════════════════════════════════════ */

(function () {
    'use strict';

    /* ── Scroll Reveal ──────────────────────────────────────── */
    function initScrollReveal() {
        var reveals = document.querySelectorAll('.reveal');
        var observer = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                    observer.unobserve(entry.target);
                }
            });
        }, {
            threshold: 0.12,
            rootMargin: '0px 0px -40px 0px'
        });

        reveals.forEach(function (el) {
            observer.observe(el);
        });
    }

    /* ── Nav Scroll Effect ──────────────────────────────────── */
    function initNavScroll() {
        var nav = document.getElementById('nav');

        window.addEventListener('scroll', function () {
            if (window.scrollY > 60) {
                nav.style.padding = '12px 32px';
                nav.style.background = 'rgba(13, 17, 23, 0.95)';
            } else {
                nav.style.padding = '18px 32px';
                nav.style.background = 'rgba(13, 17, 23, 0.8)';
            }
        });
    }

    /* ── Footer Year ────────────────────────────────────────── */
    function initFooterYear() {
        var el = document.getElementById('year');
        if (el) {
            el.textContent = new Date().getFullYear();
        }
    }

    /* ── Init ───────────────────────────────────────────────── */
    initScrollReveal();
    initNavScroll();
    initFooterYear();

})();