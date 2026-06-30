/* ═══════════════════════════════════════════════════════════════════
   i.ar — Inteligencia Avanzada Randazzo
   Static landing page
   JavaScript: boot sequence, matrix rain, typewriter, scroll reveal
   ═══════════════════════════════════════════════════════════════════ */

(function () {
    'use strict';

    /* ── Boot Sequence ──────────────────────────────────────── */
    var bootLines = [
        '[ OK ] initializing i.ar v1.0',
        '[ OK ] mounting /root/.emacs.d (read-only)',
        '[ OK ] loading init.el',
        '[ OK ] gptel backend: ollama @ 10.66.0.3:11434',
        '[ OK ] agent_loader: 9 profiles registered',
        '[ OK ] delegate_tool: hierarchical dispatch ready',
        '[ OK ] output_sanitizer: injection resistance active',
        '[ OK ] file_guard: protected paths enforced',
        '[ OK ] audit_log: append-only mode',
        '[ OK ] preflight.sh: 15 escape vectors checked',
        '[ OK ] container hardened: cap-drop=all, no-new-privileges',
        '[ OK ] wireguard mesh: 5 peers connected',
        '',
        'system ready.'
    ];

    var bootOverlay = document.getElementById('boot-overlay');
    var bootText = document.getElementById('boot-text');

    function runBootSequence() {
        var lineIndex = 0;
        var charIndex = 0;
        var lines = []; // completed lines as strings

        function typeNext() {
            if (lineIndex >= bootLines.length) {
                // Boot complete — fade out
                setTimeout(function () {
                    bootOverlay.classList.add('fade-out');
                    setTimeout(function () {
                        bootOverlay.style.display = 'none';
                        startMainAnimations();
                    }, 800);
                }, 600);
                return;
            }

            var currentLine = bootLines[lineIndex];

            if (charIndex <= currentLine.length) {
                // Build the display: completed lines + current line up to charIndex
                var display = '';
                for (var i = 0; i < lines.length; i++) {
                    display += lines[i] + '\n';
                }
                display += currentLine.substring(0, charIndex);
                bootText.textContent = display;
                charIndex++;
                setTimeout(typeNext, 12);
            } else {
                // Line complete — store it and move on
                lines.push(currentLine);
                lineIndex++;
                charIndex = 0;
                setTimeout(typeNext, 60);
            }
        }

        typeNext();
    }

    /* ── Matrix Rain ────────────────────────────────────────── */
    function initMatrixRain() {
        var canvas = document.getElementById('matrix');
        var ctx = canvas.getContext('2d');

        var columns = [];
        var fontSize = 14;
        var chars = '01∞<>{}[]()=+-*/&|!?$#@%01ABCDEF0123456789';

        function resize() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
            var colCount = Math.floor(canvas.width / fontSize);
            columns = [];
            for (var i = 0; i < colCount; i++) {
                columns[i] = {
                    y: Math.random() * canvas.height,
                    speed: 0.5 + Math.random() * 1.5,
                    chars: []
                };
            }
        }

        resize();
        window.addEventListener('resize', resize);

        function draw() {
            // Fade trail
            ctx.fillStyle = 'rgba(10, 14, 10, 0.05)';
            ctx.fillRect(0, 0, canvas.width, canvas.height);

            ctx.font = fontSize + 'px monospace';

            for (var i = 0; i < columns.length; i++) {
                var col = columns[i];
                var char = chars[Math.floor(Math.random() * chars.length)];
                var x = i * fontSize;
                var y = col.y;

                // Brighter head character
                ctx.fillStyle = '#00ff41';
                ctx.shadowBlur = 8;
                ctx.shadowColor = '#00ff41';
                ctx.fillText(char, x, y);

                // Dimmer trail
                ctx.shadowBlur = 0;
                ctx.fillStyle = 'rgba(0, 143, 36, 0.5)';
                if (col.chars.length > 0) {
                    for (var j = 0; j < col.chars.length && j < 5; j++) {
                        var trailChar = col.chars[j];
                        var trailY = y - (j + 1) * fontSize;
                        if (trailY > 0) {
                            ctx.fillText(trailChar, x, trailY);
                        }
                    }
                }

                col.chars.unshift(char);
                if (col.chars.length > 10) col.chars.pop();

                col.y += col.speed * fontSize;

                if (col.y > canvas.height + fontSize * 5) {
                    col.y = -fontSize;
                    col.speed = 0.5 + Math.random() * 1.5;
                    col.chars = [];
                }
            }
        }

        // Throttle to ~20fps for performance
        var lastDraw = 0;
        function animate(timestamp) {
            if (timestamp - lastDraw > 50) {
                draw();
                lastDraw = timestamp;
            }
            requestAnimationFrame(animate);
        }

        requestAnimationFrame(animate);
    }

    /* ── Typewriter Effect ──────────────────────────────────── */
    function initTypewriter() {
        var el = document.getElementById('typewriter');
        var text = 'Inteligencia Avanzada Randazzo.\nA self-modifying AI operating environment.\nBuilt in Emacs. Hardened in Podman. Powered by local LLMs.';

        var index = 0;

        function type() {
            if (index <= text.length) {
                el.textContent = text.substring(0, index);
                index++;
                setTimeout(type, 30);
            }
        }

        type();
    }

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
            threshold: 0.15,
            rootMargin: '0px 0px -50px 0px'
        });

        reveals.forEach(function (el) {
            observer.observe(el);
        });
    }

    /* ── Nav Scroll Effect ──────────────────────────────────── */
    function initNavScroll() {
        var nav = document.getElementById('nav');
        var lastScroll = 0;

        window.addEventListener('scroll', function () {
            var scroll = window.scrollY;

            if (scroll > 80) {
                nav.style.padding = '10px 32px';
                nav.style.background = 'rgba(10, 14, 10, 0.95)';
            } else {
                nav.style.padding = '16px 32px';
                nav.style.background = 'rgba(10, 14, 10, 0.85)';
            }

            lastScroll = scroll;
        });
    }

    /* ── Start Main Animations (after boot) ─────────────────── */
    function startMainAnimations() {
        initMatrixRain();
        initTypewriter();
        initScrollReveal();
        initNavScroll();
    }

    /* ── Boot ───────────────────────────────────────────────── */
    // Check for reduced motion preference
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
        // Skip boot sequence and matrix rain
        bootOverlay.style.display = 'none';
        document.getElementById('matrix').style.display = 'none';
        document.getElementById('typewriter').textContent =
            'Inteligencia Avanzada Randazzo. A self-modifying AI operating environment. Built in Emacs. Hardened in Podman. Powered by local LLMs.';
        initScrollReveal();
        initNavScroll();
    } else {
        runBootSequence();
    }

})();