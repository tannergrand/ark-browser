import os

HEAD = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
TILE = '<rect x="86" y="86" width="852" height="852" rx="196" ry="196" fill="{f}"/>'

# Shared mesh gradient: indigo anchor (#533AFD, already in Ark's palette) warmed
# toward coral/peach the way Arc's tile does.
MESH = '''
<defs>
  <linearGradient id="base" x1="0" y1="0" x2="0.35" y2="1">
    <stop offset="0" stop-color="#6B5BFF"/><stop offset="0.55" stop-color="#4028C9"/><stop offset="1" stop-color="#1B1252"/>
  </linearGradient>
  <radialGradient id="warm" cx="0.86" cy="0.9" r="0.85">
    <stop offset="0" stop-color="#FF6B5E" stop-opacity="0.95"/><stop offset="0.55" stop-color="#FF6B5E" stop-opacity="0.25"/><stop offset="1" stop-color="#FF6B5E" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="peach" cx="0.14" cy="0.08" r="0.7">
    <stop offset="0" stop-color="#FFC07A" stop-opacity="0.8"/><stop offset="1" stop-color="#FFC07A" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="violet" cx="0.9" cy="0.1" r="0.6">
    <stop offset="0" stop-color="#C08BFF" stop-opacity="0.65"/><stop offset="1" stop-color="#C08BFF" stop-opacity="0"/>
  </radialGradient>
  <clipPath id="tile"><rect x="86" y="86" width="852" height="852" rx="196" ry="196"/></clipPath>
</defs>
<g clip-path="url(#tile)">
  <rect x="86" y="86" width="852" height="852" fill="url(#base)"/>
  <rect x="86" y="86" width="852" height="852" fill="url(#warm)"/>
  <rect x="86" y="86" width="852" height="852" fill="url(#peach)"/>
  <rect x="86" y="86" width="852" height="852" fill="url(#violet)"/>
</g>
'''

def write(name, body):
    open(name + '.svg', 'w').write(HEAD + body + '</svg>\n')

# 1 — ARK. The current hull, restated on an Arc-style tile. Cabin dropped: at
# 32pt it was the first thing to close up.
write('1-ark', MESH + '''
<g fill="#FFFFFF">
  <path d="M296 398 L728 398 Q512 700 296 398 Z"/>
  <path d="M258 632 Q380 596 512 620 T766 632" fill="none" stroke="#FFFFFF" stroke-opacity="0.62"
        stroke-width="30" stroke-linecap="round"/>
</g>''')

# 2 — COVENANT. Genesis 9's arc: the sign *after* the ark, and literally an arc.
write('2-covenant', TILE.format(f='#0D1016') + '''
<g fill="none" stroke-linecap="round">
  <path d="M252 602 A 260 260 0 0 1 772 602" stroke="#FF6B5E" stroke-width="36"/>
  <path d="M298 602 A 214 214 0 0 1 726 602" stroke="#FFB16B" stroke-width="36"/>
  <path d="M344 602 A 168 168 0 0 1 680 602" stroke="#A855F7" stroke-width="36"/>
  <path d="M390 602 A 122 122 0 0 1 634 602" stroke="#6B5BFF" stroke-width="36"/>
  <path d="M266 690 Q390 656 512 678 T758 690" stroke="#F4F2EE" stroke-opacity="0.75" stroke-width="28"/>
</g>''')

# 3 — APERTURE. No boat at all — one open ring, the way Arc's mark is pure
# geometry. The gap is the hatch.
write('3-aperture', MESH + '''
<circle cx="512" cy="512" r="196" fill="none" stroke="#FFFFFF" stroke-width="104"
        stroke-linecap="round" stroke-dasharray="880 351"
        transform="rotate(128 512 512)"/>''')

# 4 — SWELL. The hull dissolved into the water it rides: one ribbon, one wake.
write('4-swell', MESH + '''
<g fill="none" stroke-linecap="round">
  <path d="M262 566 C 380 372 644 760 762 470" stroke="#FFFFFF" stroke-width="92"/>
  <path d="M300 690 C 400 620 624 758 724 664" stroke="#FFFFFF" stroke-opacity="0.42" stroke-width="46"/>
</g>''')

# 5 — KEEL. Same mark as (1), tile and mark swapped. Reads bright in a dark Dock
# instead of dark in a light one.
write('5-keel', TILE.format(f='#F4F2EE') + '''
<defs>
  <linearGradient id="hull" x1="0" y1="0" x2="0.6" y2="1">
    <stop offset="0" stop-color="#6B5BFF"/><stop offset="0.6" stop-color="#7C3BE0"/><stop offset="1" stop-color="#FF6B5E"/>
  </linearGradient>
</defs>
<path d="M296 398 L728 398 Q512 700 296 398 Z" fill="url(#hull)"/>
<path d="M258 632 Q380 596 512 620 T766 632" fill="none" stroke="#8B93A7"
      stroke-width="30" stroke-linecap="round"/>''')

print('\n'.join(sorted(f for f in os.listdir('.') if f.endswith('.svg'))))
