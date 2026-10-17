from PIL import Image, ImageDraw, ImageFilter
import math, sys
S=4096
def lerp(a,b,t): return a+(b-a)*t
def grad_color(t, stops):
    for i in range(len(stops)-1):
        t0,c0=stops[i]; t1,c1=stops[i+1]
        if t<=t1:
            u=(t-t0)/(t1-t0) if t1>t0 else 0
            return tuple(int(lerp(c0[k],c1[k],u)) for k in range(3))
    return stops[-1][1]
stops=[(0,(255,138,76)),(0.45,(240,56,107)),(1,(110,60,240))]
# diagonal gradient via small image then resize
g=Image.new('RGB',(256,256))
px=g.load()
for y in range(256):
    for x in range(256):
        t=(x*0.55+y*0.45)/255
        px[x,y]=grad_color(min(1,t),stops)
bg=g.resize((S,S),Image.BICUBIC)
# soft highlight top-left
hl=Image.new('L',(S,S),0); d=ImageDraw.Draw(hl)
d.ellipse((-S*0.35,-S*0.45,S*0.75,S*0.55),fill=70)
hl=hl.filter(ImageFilter.GaussianBlur(S*0.12))
bg=Image.composite(Image.new('RGB',(S,S),(255,255,255)),bg,hl)
# vignette bottom-right
vg=Image.new('L',(S,S),0); d=ImageDraw.Draw(vg)
d.ellipse((S*0.45,S*0.5,S*1.5,S*1.5),fill=60)
vg=vg.filter(ImageFilter.GaussianBlur(S*0.15))
bg=Image.composite(Image.new('RGB',(S,S),(40,10,90)),bg,vg)

fg=Image.new('L',(S,S),0); d=ImageDraw.Draw(fg)
def bez(p0,p1,p2,p3,n=400):
    return [((1-t)**3*p0[0]+3*(1-t)**2*t*p1[0]+3*(1-t)*t*t*p2[0]+t**3*p3[0],
             (1-t)**3*p0[1]+3*(1-t)**2*t*p1[1]+3*(1-t)*t*t*p2[1]+t**3*p3[1]) for t in [i/n for i in range(n+1)]]
u=S/1024
# cursive signature: loop, then a sweeping tail that becomes the baseline into the bars
segs=[
 bez((470,330),(420,250),(250,250),(250,370)),     # top of the S
 bez((250,370),(250,480),(470,470),(470,600)),     # spine
 bez((470,600),(470,740),(230,760),(220,650)),     # bottom bowl
 bez((220,650),(260,720),(420,700),(520,640)),     # flourish back under
 bez((520,640),(570,610),(600,600),(640,612)),     # tail into the bars
]
bars=[(700,150),(762,290),(824,200),(886,360),(948,170)]
cy=560
# center everything
allp=[p for sg in segs for p in sg]
minx=min(p[0] for p in allp); maxx=max(bars[-1][0]+20,max(p[0] for p in allp))
miny=min(min(p[1] for p in allp),cy-max(h for _,h in bars)/2); maxy=max(max(p[1] for p in allp),cy+max(h for _,h in bars)/2)
dx=512-(minx+maxx)/2; dy=512-(miny+maxy)/2
K=0.84
segs=[[(512+(x+dx-512)*K,512+(y+dy-512)*K) for x,y in sg] for sg in segs]
bars=[(512+(x+dx-512)*K,h*K) for x,h in bars]; cy=512+(cy+dy-512)*K
pts=[p for sg in segs for p in sg]
W=50*0.86
for i,(x,y) in enumerate(pts):
    t=i/len(pts)
    w=W*(0.45+0.55*math.sin(math.pi*min(1,0.08+t*0.95)))
    d.ellipse(((x-w/2)*u,(y-w/2)*u,(x+w/2)*u,(y+w/2)*u),fill=255)
for x,h in bars:
    bw=38
    d.rounded_rectangle(((x-bw/2)*u,(cy-h/2)*u,(x+bw/2)*u,(cy+h/2)*u),radius=bw/2*u,fill=255)
# shadow
sh=fg.filter(ImageFilter.GaussianBlur(S*0.012))
shadow=Image.new('RGB',(S,S),(60,10,80))
bg=Image.composite(shadow,bg,sh.point(lambda v:int(v*0.45)))
bg=Image.composite(Image.new('RGB',(S,S),(255,255,255)),bg,fg)
out=bg.resize((1024,1024),Image.LANCZOS)
out.save(sys.argv[1])
out.resize((256,256),Image.LANCZOS).save('preview256.png')
