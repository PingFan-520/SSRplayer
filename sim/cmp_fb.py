import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
p=os.path.join(HERE,'fb_sdram.ppm')
f=open(p,'rb')
assert f.readline().strip()==b'P6'
w,h=map(int,f.readline().split())
f.readline()
d=f.read()
FW,FH=1280,720
X0,Y0,IW,IH=320,120,640,480
bad=0; tot=0; rowbad=[0]*IH
for y in range(IH):
    base=((Y0+y)*FW+X0)*3
    for x in range(IW):
        r5=(x&255)>>3; g6=(y&255)>>2
        b5=31 if (((x>>5)+(y>>5))&1) else 0
        er=r5<<3; eg=g6<<2; eb=b5<<3
        o=base+x*3
        if d[o]!=er or d[o+1]!=eg or d[o+2]!=eb:
            bad+=1; rowbad[y]+=1
        tot+=1
print("size %dx%d  pixels %d  wrong %d  = %.2f%% ok"%(w,h,tot,bad,100.0*(tot-bad)/tot))
# 前 12 行 + 每 40 行采样
for y in list(range(0,12))+list(range(0,IH,40)):
    print("  row %3d : %d wrong"%(y,rowbad[y]))
