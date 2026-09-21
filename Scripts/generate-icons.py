#!/usr/bin/env python3
"""Emit editable SVG originals. Render with qlmanage -t -s 1024, then export RGB PNG."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
variants = {'Light': ('#FAFCFB','#065C49','#35CF94','#6A9FF7'), 'Dark': ('#142821','#BAF5D9','#259D77','#568DDD'), 'Tinted': ('#202020','#F2F2F2','#777777','#AAAAAA')}
for name, (bg, ink, green, blue) in variants.items():
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>iGPS to Health — {name}</title>
  <rect width="1024" height="1024" fill="{bg}"/>
  <g transform="translate(-30 -69) scale(1.06)">
    <circle cx="285" cy="581" r="124" fill="{green}"/>
    <circle cx="691" cy="581" r="124" fill="{blue}"/>
    <g fill="none" stroke="{ink}" stroke-width="27" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="321" cy="558" r="123"/>
      <circle cx="727" cy="558" r="123"/>
      <path d="M352 338 C414 309 437 368 402 416 C364 465 333 504 322 559"/>
      <path d="M381 442 C438 386 556 342 608 355 C646 364 637 391 608 414 C569 444 542 485 552 529 C568 598 646 606 745 551"/>
      <path d="M704 525 L745 549 L733 599"/>
    </g>
  </g>
</svg>
'''
    (root / 'Design' / f'AppIcon-{name}.svg').write_text(svg)
images=[]
for name in variants:
    item={'filename':f'AppIcon-{name}.png','idiom':'universal','platform':'ios','size':'1024x1024'}
    if name != 'Light': item['appearances']=[{'appearance':'luminosity','value':name.lower()}]
    images.append(item)
(root/'FITHealth/Assets.xcassets/AppIcon.appiconset/Contents.json').write_text(json.dumps({'images':images,'info':{'author':'xcode','version':1}},indent=2)+'\n')
(root/'FITHealth/Assets.xcassets/Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
