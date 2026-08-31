# Kite — Spec visuelle (thème sombre premium)

Direction choisie : sombre premium — fond noir profond, accent ambre/cuivre,
type serif en display. Esprit Nothing OS × Arc : surface mates, hiérarchie
sobre, un seul accent par écran.

## Tokens OKLch (binding des six variables)

| Rôle | Valeur | Usage |
|---|---|---|
| `--bg` | `#0a0a0c` (noir profond) | fond d'écran, jamais #000 brut |
| `--surface` | `#141416` | cartes, modales, zones surélevées |
| `--surface-2` | `#1c1c20` | avatars, séparateurs ton sur ton |
| `--fg` | `#ececea` | texte principal, jamais #fff brut |
| `--muted` | `#8e8e93` | texte secondaire, légendes, timestamps |
| `--border` | `#242428` | hairlines, diviseurs, contours |
| `--accent` | `#d9985f` | ambre/cuivre — 1 seul accent, max 2×/écran |

Teintes dérivées (jamais de hex inventé) :
`--accent-ink` = `#14100c` (texte sur l'accent),
`--accent-soft` = `color-mix(in oklch, var(--accent) 16%, transparent)`,
`--fg-soft` = `color-mix(in oklch, var(--fg) 7%, transparent)`.

## Typographie

- **Display** : `'Iowan Old Style', 'Charter', Georgia, serif` — titres d'écran (Discussions, Contacts…), en graisse 500.
- **Corps** : `-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif`.
- **Mono** : `ui-monospace, 'JetBrains Mono', 'SF Mono', Menlo, monospace` — horodatages, compteurs, badges, numériques.

## Langage visuel (règles observées)

1. Fond noir profond `#0a0a0c` ; les ayants droit sont des cartes `--surface` / `--surface-2` mates, jamais des dégradés violacés.
2. Un seul accent `--accent` par écran, deux occurrences maximum — classiquement l'eyebrow/TAB actif + un badge/compteur. Les images/état envoyé utilisent le cuivre sur `--accent` inversé.
3. Avatars à initiales teintées (`--tint-1` lavande, `--tint-2` émeraude, `--tint-3` miel) sur `--surface-2` — jamais de vraies photos pour les contacts.
4. Boutons ronds (icône 38–40px), coins arrondis 12–18px, messages en bulles 18px avec pince sur le dernier coin.
5. États : hover = `--bg` → `--fg-soft` (jamais texte plus clair), focus-visible = anneau `--accent`, envoi lu = ticks cuivre `--accent`.
6. Navigation configurable : barre basse flottante, barre haute, sidebar, navigation compacte, icônes seulement — variante par défaut à 3 onglets (Discussions / Communautés / Appels), onglet actif en `--accent`.

## Résumé

Messagerie premium éponyme « Kite » : fond noir mat, cuivre ambre réservé aux
signaux, serif en display, hiérarchie calme — parité fonctionnelle WhatsApp
sans en copier la marque.
