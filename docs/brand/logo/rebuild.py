"""Rebuild the thinktin G1.0 SVG master using only the Python standard library.
Usage: python3 rebuild.py [path/to/thinktin-geometry.json] [output_directory]
The JSON is the authoritative geometry. No source image, font or network needed.
"""
import json, math, csv, sys
from pathlib import Path
from xml.sax.saxutils import escape

def num(x): return f'{x:.9f}'.rstrip('0').rstrip('.') if x else '0'
def xy(p): return ' '.join(num(x) for x in p)
def path_d(path):
    segs=path['segments']; parts=['M '+xy(segs[0]['p0'])]
    for a in segs:
        if a['type']=='line':parts.append('L '+xy(a['p1']))
        else:parts.append(f"A {num(a['r'])} {num(a['r'])} 0 {int(abs(a['da'])>math.pi)} {int(a['da']>0)} {xy(a['p1'])}")
    if path['closed']:parts.append('Z')
    return ' '.join(parts)

def gradient_xml(g):
    at=' '.join(f'{k}="{num(g[k])}"' for k in ['x1','y1','x2','y2'])
    st=''.join(f'<stop offset="{num(t)}" stop-color="{c}"/>' for t,c in g['stops'])
    return f'<linearGradient id="thinktin-gradient" gradientUnits="userSpaceOnUse" color-interpolation="sRGB" {at}>{st}</linearGradient>'

def logo_xml(spec,mono=False,thin=False):
    out=[]
    for p in spec['paths']:
        color='url(#thinktin-gradient)' if p['id']=='S' and not mono else '#000000'
        w=p['stroke'] if not thin else 2.0
        out.append(f'<path id="{p["id"]}" d="{path_d(p)}" fill="none" stroke="{color}" stroke-width="{num(w)}" stroke-linecap="round" stroke-linejoin="round"/>')
    return '\n'.join(out)

def master(spec,mono=False):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" viewBox="0 0 1000 1000">
<title>thinktin G1.0 - {'monochrome' if mono else 'gradient'} circular-arc master</title>
<desc>Reproducible 1000 U square. Straight lines and circular arcs only. See thinktin-geometry.json for full precision.</desc>
<defs>{gradient_xml(spec['gradient'])}</defs>
<rect width="1000" height="1000" fill="#FFFFFF"/>
{logo_xml(spec,mono)}
</svg>'''

def sample_arc(a,n=100):
    if a['type']=='line':return [[a['p0'][0]+(a['p1'][0]-a['p0'][0])*i/(n-1),a['p0'][1]+(a['p1'][1]-a['p0'][1])*i/(n-1)] for i in range(n)]
    return [[a['c'][0]+a['r']*math.cos(a['a0']+a['da']*i/(n-1)),a['c'][1]+a['r']*math.sin(a['a0']+a['da']*i/(n-1))] for i in range(n)]

def construction(spec):
    a=['<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1200" viewBox="0 0 1600 1200">',
       '<rect width="1600" height="1200" fill="#F7FAFC"/>',
       '<style>text{font-family:DejaVu Sans,Arial,sans-serif} .mono{font-family:DejaVu Sans Mono,monospace}</style>',
       '<defs><clipPath id="chart"><rect x="0" y="0" width="1000" height="1000"/></clipPath>',gradient_xml(spec['gradient']),'</defs>',
       '<text x="56" y="63" fill="#152C40" font-size="30" font-weight="bold">thinktin</text>',
       '<text x="56" y="96" fill="#537287" font-size="14" letter-spacing="2">G1.0 / CIRCULAR-ARC CONSTRUCTION</text>',
       '<text x="1544" y="63" text-anchor="end" fill="#537287" font-size="14">1000 U x 1000 U</text>',
       '<g transform="translate(45,140) scale(.93)">',
       '<rect width="1000" height="1000" fill="white" stroke="#C8DCE8"/>']
    for v in range(0,1001,50):
        col='#D8E7EF' if v%100==0 else '#ECF2F6'
        a.append(f'<path d="M {v} 0 V1000 M0 {v} H1000" stroke="{col}" stroke-width=".7"/>')
    a.append('<g clip-path="url(#chart)">')
    for p in spec['paths']:
        c='#55A5BB' if p['id']!='S' else '#B68BBC'
        for i,s in enumerate(p['segments']):
            if s['type']!='arc':continue
            # Every helper circle corresponds to an actual segment.
            a.append(f'<circle cx="{num(s["c"][0])}" cy="{num(s["c"][1])}" r="{num(s["r"])}" stroke="{c}" stroke-width=".8" opacity=".32" fill="none"/>')
            if 0<s['c'][0]<1000 and 0<s['c'][1]<1000:
                x,y=s['c'];a.append(f'<path d="M{x-3} {y}h6 M{x} {y-3}v6" stroke="{c}" stroke-width=".7"/>')
    a.append('</g>')
    a.append(f'<g opacity=".78">{logo_xml(spec,False)}</g>')
    a.append('<path d="M500 0V1000 M0 500H1000" stroke="#6FA5BB" stroke-width="1.2" stroke-dasharray="7 6"/>')
    for p in spec['paths']:
        for i,s in enumerate(p['segments']):
            if i%4==0:
                x,y=s['p0'];a.append(f'<circle cx="{x}" cy="{y}" r="3" fill="#D66C50"/><text x="{x+7}" y="{y-7}" font-size="10" fill="#8E503D">{s["id"]}</text>')
    a.append('</g>')
    a+=['<text x="1045" y="183" font-size="16" font-weight="bold" fill="#17374A">GEOMETRY DEFINES THE MARK</text>',
        '<text x="1045" y="217" font-size="14" fill="#537287">Real guide circles. Tangent joins.</text>',
        '<text x="1045" y="244" font-size="14" fill="#537287">No decorative or arbitrary construction lines.</text>',
        '<g transform="translate(1090,270) scale(.36)">',logo_xml(spec),'</g>',
        '<text x="1045" y="690" font-size="14" font-weight="bold" fill="#17374A">REBUILD KEY</text>']
    lines=['Canvas: 1000 x 1000 U','Origin: upper-left; +x right, +y down','Outline strokes: B 22 / R 21 / I 16.5 U','Loop stroke: 22 U; round caps','Scale: 1 U = output width / 1000','100 mm master: 1 U = 0.1 mm','Full geometry: JSON + SVG + arc CSV','This normalized master is the 1:1 reference.']
    for i,line in enumerate(lines):a.append(f'<text x="1045" y="{725+i*29}" font-size="13" fill="#537287" class="mono">{escape(line)}</text>')
    a+=['<line x1="56" y1="1125" x2="1544" y2="1125" stroke="#CFDEE8"/>',
        '<text x="56" y="1154" font-size="12" fill="#537287">Fitted and geometrically normalized from the approved raster. Not a pixel-identical raster trace.</text>',
        '<text x="1544" y="1154" text-anchor="end" font-size="12" fill="#537287">2026.10.30 / G1.0</text></svg>']
    return '\n'.join(a)

def validate(spec):
    max_rad=max_gap=max_tan=0.0;count=0
    def tangent(s,at_end):
        if s['type']=='line':v=[s['p1'][i]-s['p0'][i] for i in (0,1)]
        else:
            p=s['p1'] if at_end else s['p0'];v=[-(p[1]-s['c'][1]),p[0]-s['c'][0]]
            if s['da']<0:v=[-v[0],-v[1]]
        n=math.hypot(*v);return [v[0]/n,v[1]/n]
    for p in spec['paths']:
        ss=p['segments']
        for s in ss:
            count+=1
            if s['type']=='arc':
                for v in (s['p0'],s['p1']):max_rad=max(max_rad,abs(math.dist(v,s['c'])-s['r']))
        pairs=list(zip(ss,ss[1:]))+([(ss[-1],ss[0])] if p['closed'] else [])
        for aa,bb in pairs:
            max_gap=max(max_gap,math.dist(aa['p1'],bb['p0']))
            ta,tb=tangent(aa,True),tangent(bb,False)
            max_tan=max(max_tan,math.degrees(math.acos(max(-1,min(1,sum(x*y for x,y in zip(ta,tb)))))))
    return {'segment_count':count,'max_endpoint_circle_error_U':max_rad,'max_join_gap_U':max_gap,'max_tangent_angle_error_deg':max_tan,'circle_endpoint_pass':max_rad<1e-6,'join_pass':max_gap<1e-6,'tangent_pass':max_tan<1e-3}

def build(spec,out):
    out.mkdir(parents=True,exist_ok=True)
    (out/'thinktin-master-gradient.svg').write_text(master(spec),encoding='utf-8')
    (out/'thinktin-master-black.svg').write_text(master(spec,True),encoding='utf-8')
    (out/'thinktin-construction.svg').write_text(construction(spec),encoding='utf-8')
    with (out/'thinktin-arc-table.csv').open('w',newline='',encoding='utf-8-sig') as f:
        w=csv.writer(f);w.writerow(['id','part','kind','start_x_U','start_y_U','end_x_U','end_y_U','center_x_U','center_y_U','radius_U','start_angle_deg','sweep_deg','direction','stroke_U'])
        for p in spec['paths']:
            for a in p['segments']:
                w.writerow([a['id'],p['name'],a['type'],*a['p0'],*a['p1'],*(a.get('c',['',''])),a.get('r',''),math.degrees(a['a0']) if 'a0'in a else '',math.degrees(a['da']) if 'da'in a else '',('CW' if a['da']>0 else 'CCW') if 'da'in a else '',p['stroke']])
    report=validate(spec)
    (out/'geometry-validation.json').write_text(json.dumps(report,indent=2))
    if not all(report[x] for x in ['circle_endpoint_pass','join_pass','tangent_pass']):raise ValueError(report)
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    default=Path(__file__).resolve().parent
    source=Path(sys.argv[1]) if len(sys.argv)>1 else default/'thinktin-geometry.json'
    out=Path(sys.argv[2]) if len(sys.argv)>2 else default
    build(json.loads(source.read_text()),out)
